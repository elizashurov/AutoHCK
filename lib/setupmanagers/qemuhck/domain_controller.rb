# frozen_string_literal: true

require 'resolv'

module AutoHCK
  class QemuHCK
    # Owns a persistent DC for the whole session, independently of the HLK pool.
    class DomainController
      include Helper

      POLL_INTERVAL = 5
      PROBE_TIMEOUT = 2

      def initialize(project, config, options)
        @logger = project.logger
        @project = project
        @config = config
        @options = options
      end

      def start(scope)
        scope.transaction do |resources|
          lock_files(resources)
          machine = QemuMachine.new(@project, @options)
          check_images(machine.config.fetch('qemu_img_bin'))
          @logger.info("Starting persistent DC #{@config.name}; no DC overlay will be created")
          runner = machine.run(resources, create_snapshot: false, keep_alive: false, secure: false)
          wait_ready(runner)
          runner
        end
      end

      private

      def lock_files(scope)
        paths = [@config.image, @config.nvram].map { |path| File.realpath(path) }
        raise InvalidConfigFile, 'DC image and NVRAM refer to the same file' if File.identical?(*paths)

        paths.each { |path| lock_file(scope, path) }
        @logger.info("Exclusive DC ownership acquired for #{@config.image}")
      end

      def lock_file(scope, path)
        # ResourceScope closes the file after the VM, including on startup failure.
        file = File.open(path, 'r+') # rubocop:disable Style/FileOpen
        scope << file
        raise InvalidConfigFile, "DC state must be a regular file: #{path}" unless file.stat.file?
        return if file.flock(File::LOCK_EX | File::LOCK_NB)

        raise MachineRunError, "DC state is already owned by another session: #{path}"
      end

      # The QCOW2 metadata check also detects an externally launched QEMU via
      # QEMU's image locks. Never use --force-share or disable QEMU locking.
      def check_images(qemu_img)
        [[@config.image, 'qcow2'], [@config.nvram, 'raw']].each do |path, format|
          run_cmd(qemu_img, 'info', '-f', format, path)
        end
      rescue CmdRunError => e
        raise MachineRunError, "DC image check failed; a file may already be in use. No DC was launched. #{e.message}"
      end

      def wait_ready(runner)
        deadline = monotonic_time + @config.readiness_timeout
        @logger.info("Waiting for DC #{@config.name} at #{@config.ip}: DNS, LDAP and SMB")
        loop do
          verify_running(runner)
          if services_reachable?
            @logger.info("DC #{@config.name} is reachable: domain DNS records, LDAP and SMB verified")
            return
          end
          if monotonic_time >= deadline
            raise MachineRunError, "DC readiness timed out after #{@config.readiness_timeout}s: #{@last_probe_error}"
          end

          sleep POLL_INTERVAL
        end
      end

      def verify_running(runner)
        return if runner.alive?

        runner.wait # Propagate startup errors from the QEMU thread.
        raise MachineRunError, 'DC QEMU exited before the domain services became reachable'
      end

      def services_reachable?
        verify_dns
        [389, 445].each do |port|
          Socket.tcp(@config.ip, port, connect_timeout: PROBE_TIMEOUT, &:close)
        end
        true
      rescue Resolv::ResolvError, Resolv::ResolvTimeout, SystemCallError, IOError, SocketError => e
        @last_probe_error = e.message
        @logger.debug("DC not reachable yet: #{@last_probe_error}")
        false
      end

      def verify_dns
        fqdn = "#{@config.name}.#{@config.domain}"
        Resolv::DNS.open(nameserver: [@config.ip], search: [], ndots: 1) do |dns|
          dns.timeouts = PROBE_TIMEOUT
          verify_host_record(dns, fqdn)
          verify_locator_record(dns, fqdn)
        end
      end

      def verify_host_record(dns, fqdn)
        addresses = dns.getresources("#{fqdn}.", Resolv::DNS::Resource::IN::A)
        return if addresses.any? { |record| record.address.to_s == @config.ip }

        raise Resolv::ResolvError, "#{fqdn} does not resolve to #{@config.ip} on the DC"
      end

      def verify_locator_record(dns, fqdn)
        records = dns.getresources("_ldap._tcp.dc._msdcs.#{@config.domain}.", Resolv::DNS::Resource::IN::SRV)
        return if records.any? { |record| record.port == 389 && record.target.to_s.casecmp?(fqdn) }

        raise Resolv::ResolvError, "Domain LDAP SRV record does not advertise #{fqdn}"
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
