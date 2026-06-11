# frozen_string_literal: true

require 'net/ssh'
require 'net/scp'
require 'securerandom'
require 'socket'

module AutoHCK
  module Functest
    # FunctestTools: thin SSH wrapper for direct communication with a Windows VM.
    # Analogous to rtoolsHCK's machine_connection path (upload_to_machine / run_on_machine)
    # but without any HLK dependency — connects straight to the client VM using its
    # world-facing IP, bypassing the studio entirely.
    class FunctestTools
      SSH_DEFAULT_PORT = 22
      WAIT_TIMEOUT = 600
      WAIT_INTERVAL = 10
      REBOOT_SETTLE_SLEEP = 30

      def initialize(ip, username, password, logger, port: SSH_DEFAULT_PORT)
        @ip = ip
        @username = username
        @password = password
        @logger = logger
        @port = port
        @session = connect
      end

      # Runs a PowerShell command; raises on non-zero exit code.
      def cmd(command)
        @logger.debug("SSH cmd: #{command[0..120]}")
        stdout = +''; stderr = +''; exit_code = nil

        channel = @session.open_channel do |ch|
          ch.exec(command) do |_, success|
            raise AutoHCKError, 'Failed to open SSH channel for command' unless success

            ch.on_data             { |_, data| stdout << data }
            ch.on_extended_data    { |_, _, data| stderr << data }
            ch.on_request('exit-status') { |_, data| exit_code = data.read_long }
          end
        end
        channel.wait
        @session.loop

        check_run_output(stdout, stderr, exit_code, command)
        stdout
      end

      # Uploads a local file or directory to an explicit remote path on the VM.
      # For directories, delegates to upload_directory which handles the SCP
      # exists/not-exists placement correctly. For files, ensures the parent
      # directory exists before uploading so SCP does not fail with "No such
      # file or directory".
      def upload(local_path, remote_path)
        @logger.debug("SCP upload: #{local_path} -> #{remote_path}")
        if File.directory?(local_path)
          upload_directory(local_path, remote_path)
        else
          parent = remote_path.rpartition('\\').first
          cmd("New-Item -ItemType Directory -Force -Path '#{parent}' | Out-Null") unless parent.empty?
          @session.scp.upload!(local_path, remote_path)
        end
      rescue StandardError => e
        raise AutoHCKError, "Upload failed (#{local_path} -> #{remote_path}): #{e.message}"
      end

      # Uploads a local directory to a path on the VM.
      # If no remote_path is given, a unique subdirectory under C:\Windows\Temp is chosen.
      # Returns the remote path as a Windows-style string (backslashes).
      #
      # IMPORTANT: the remote path must NOT exist before SCP runs. If it already exists,
      # SCP creates a subdirectory named after the local basename inside it instead of
      # placing files directly at r_path. We ensure the parent exists and remove any
      # stale target before uploading.
      def upload_directory(local_path, remote_path = nil)
        r_path = remote_path || "C:\\Windows\\Temp\\#{SecureRandom.uuid}"
        @logger.debug("SCP upload dir: #{local_path} -> #{r_path}")
        parent = r_path.rpartition('\\').first
        cmd("New-Item -ItemType Directory -Force -Path '#{parent}' | Out-Null") unless parent.empty?
        cmd("if (Test-Path '#{r_path}') { Remove-Item -Recurse -Force '#{r_path}' }")
        @session.scp.upload!(local_path, r_path, recursive: true)
        r_path
      rescue StandardError => e
        raise AutoHCKError, "Upload failed (#{local_path} -> #{r_path}): #{e.message}"
      end

      # Downloads a remote file or directory from the VM to a local path.
      def download(remote_path, local_path)
        @logger.debug("SCP download: #{remote_path} -> #{local_path}")
        @session.scp.download!(remote_path, local_path)
      rescue StandardError => e
        raise AutoHCKError, "Download failed (#{remote_path} -> #{local_path}): #{e.message}"
      end

      # Installs a driver package. Mirrors rtoolsHCK's do_install_machine_driver_package logic.
      def install_driver_package(install_method, local_dir, inf_file,
                                 custom_cmd: nil, sys_file: nil, force_install_cert: false)
        @logger.info("Installing #{install_method} driver #{inf_file}")
        r_directory = upload_driver_dir(local_dir)
        windows_path = "#{r_directory}\\#{inf_file}"

        install_certificate(windows_path, sys_file) if install_method.eql?('PNP') || force_install_cert

        output = cmd(driver_install_command(r_directory, windows_path, install_method, custom_cmd))
        @logger.info("pnputil output: #{output.strip}") unless output.strip.empty?
      end

      # Issues a reboot and blocks until SSH is reachable again.
      # The VM may drop the SSH connection before the shutdown command returns an exit
      # status, so disconnection errors and AutoHCKError caused by a missing
      # exit-status are treated as a successful reboot trigger.
      def restart_and_wait
        @logger.info('Rebooting guest...')
        begin
          cmd('shutdown -r -f -t 0')
        rescue Net::SSH::Disconnect, IOError, AutoHCKError
          @logger.debug('SSH disconnected during reboot — expected, continuing')
        end
        begin
          @session.close if @session && !@session.closed?
        rescue StandardError
          nil
        end
        @logger.info("Sleeping #{REBOOT_SETTLE_SLEEP}s for VM to begin shutdown...")
        sleep REBOOT_SETTLE_SLEEP
        @session = connect
      end

      private

      def connect
        wait_for_ssh_port
        @logger.info("Connecting SSH to #{@ip}:#{@port}...")
        deadline = Time.now + WAIT_TIMEOUT
        begin
          Net::SSH.start(
            @ip, @username,
            password: @password,
            port: @port,
            non_interactive: true,
            verify_host_key: :never,
            timeout: 10
          )
        rescue Net::SSH::Exception, Errno::ECONNREFUSED, Errno::ECONNRESET,
               Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
          raise "SSH not ready after #{WAIT_TIMEOUT}s: #{e.message}" if Time.now > deadline

          @logger.debug("SSH not ready yet (#{e.class}), retrying...")
          sleep WAIT_INTERVAL
          retry
        end
      end

      def wait_for_ssh_port
        @logger.info("Waiting for SSH on #{@ip}:#{@port}...")
        deadline = Time.now + WAIT_TIMEOUT
        until ssh_port_open?
          raise "SSH port not open after #{WAIT_TIMEOUT}s on #{@ip}:#{@port}" if Time.now > deadline

          sleep WAIT_INTERVAL
        end
      end

      def ssh_port_open?
        TCPSocket.new(@ip, @port).close
        true
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Errno::ENETUNREACH
        false
      end

      def check_run_output(stdout, stderr, exit_code, command)
        return if exit_code&.zero?

        code_str = exit_code.nil? ? 'unknown (no exit-status received)' : exit_code.to_s
        error = "Running '#{command[0..120]}' failed with exit code #{code_str}." \
                "#{stdout.strip.empty? ? '' : "\n   -- stdout:\n#{stdout.strip}"}" \
                "#{stderr.strip.empty? ? '' : "\n   -- stderr:\n#{stderr.strip}"}"
        raise AutoHCKError, error
      end

      def upload_driver_dir(local_dir)
        # UUID path is guaranteed not to exist; do not pre-create it so SCP places
        # the driver files directly inside r_directory rather than in a subdirectory.
        # C:\Windows\Temp always exists so no parent creation is needed.
        r_directory = "C:\\Windows\\Temp\\#{SecureRandom.uuid}"
        @logger.debug("SCP upload driver dir: #{local_dir} -> #{r_directory}")
        @session.scp.upload!(local_dir, r_directory, recursive: true)
        r_directory
      rescue StandardError => e
        raise AutoHCKError, "Driver dir upload failed (#{local_dir}): #{e.message}"
      end

      def guest_dirname(windows_path)
        windows_path.split('\\')[0..-2].join('\\')
      end

      def export_certificate_script(sys_path, cer_path)
        [
          '$exportType = [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert',
          "$cert = (Get-AuthenticodeSignature '#{sys_path}').SignerCertificate",
          'if ($cert -eq $null) { exit(-1) }',
          "[System.IO.File]::WriteAllBytes('#{cer_path}', $cert.Export($exportType))"
        ].join('; ')
      end

      def install_certificate_script(cer_path)
        [
          "certutil -enterprise -f -v -AddStore Root '#{cer_path}'",
          "certutil -enterprise -f -v -AddStore TrustedPublisher '#{cer_path}'"
        ].join('; ')
      end

      def install_certificate(windows_path, sys_file)
        sys_path = if sys_file.nil?
                     windows_path.sub('.inf', '.sys')
                   else
                     "#{guest_dirname(windows_path)}\\#{sys_file}"
                   end
        cer_path = "#{guest_dirname(windows_path)}\\#{SecureRandom.uuid}.cer"

        cmd(export_certificate_script(sys_path, cer_path))
        cmd(install_certificate_script(cer_path))
      end

      def driver_install_command(r_directory, windows_path, install_method, custom_cmd)
        case install_method
        when 'PNP'
          "pnputil -i -a \"#{windows_path}\""
        when 'NON-PNP'
          "RUNDLL32.EXE SETUPAPI.DLL,InstallHinfSection DefaultInstall 128 \"#{windows_path}\""
        when 'custom'
          custom_cmd
            .gsub('@driver_dir@', r_directory)
            .gsub('@inf_path@', windows_path)
        else
          raise AutoHCKError, "Unknown driver install method: #{install_method}"
        end
      end
    end
  end
end
