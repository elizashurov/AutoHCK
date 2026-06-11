# frozen_string_literal: true

require 'timeout'
require 'open3'

module AutoHCK
  module Functest
    # StepHandler executes individual test steps via a FunctestTools instance
    class StepHandler

      def initialize(project, tools, context, default_timeout:)
        @project = project
        @tools = tools
        @context = context
        @logger = project.logger
        @default_timeout = default_timeout
      end

      def execute_step(step, step_index)
        desc = @context.substitute_variables(step['desc'] || "Step #{step_index + 1}")
        @logger.info("Executing: #{desc}")

        timeout = step['timeout'] || @default_timeout

        Timeout.timeout(timeout) do
          execute_step_action(step, desc)
        end
      rescue Timeout::Error
        handle_step_error(step, "Timeout after #{timeout}s: #{desc}")
      rescue StandardError => e
        @logger.error("Step failed: #{desc} - #{e.message}")
        handle_step_error(step, e.message)
      end

      private

      def execute_step_action(step, desc)
        if step['guest_run']
          handle_guest_run(step, desc)
        elsif step['files_action']
          handle_files_action(step)
        elsif step['guest_reboot']
          handle_guest_reboot(step)
        elsif step['host_run']
          handle_host_run(step)
        elsif step['barrier']
          handle_barrier(step)
        else
          @logger.warn("Unknown step type in: #{desc}")
        end
      end

      def handle_guest_run(step, desc = nil)
        command = step['guest_run']
        desc ||= command[0..60]

        command = @context.substitute_variables(command, step['variables'] || {})

        @logger.debug("Guest command: #{command}")

        output = @tools.cmd(command)

        if step['capture_output']
          @context.set_variable(step['capture_output'], output.strip)
          @logger.debug("Captured '#{step['capture_output']}': #{output[0..100]}")
        end

        validate_output(output, step)

        { stdout: output }
      end

      def handle_files_action(step)
        step['files_action'].each do |file_op|
          local_path = @context.substitute_variables(file_op['local_path'] || '')
          remote_path = @context.substitute_variables(file_op['remote_path'] || '')
          allow_missing = file_op['allow_missing']
          move = file_op['move']

          case file_op['direction']
          when 'local-to-remote'
            full_local = File.absolute_path?(local_path) ? local_path : File.join(Dir.pwd, local_path)
            unless File.exist?(full_local)
              if allow_missing
                @logger.warn("Local file not found, skipping: #{full_local}")
                next
              end
              raise "Local file not found: #{full_local}"
            end

            @logger.debug("Uploading: #{full_local} -> #{remote_path}")
            @tools.upload(full_local, remote_path)
            FileUtils.rm_rf(full_local) if move

          when 'remote-to-local'
            @logger.debug("Downloading: #{remote_path} -> #{local_path}")
            FileUtils.mkdir_p(File.dirname(local_path))
            begin
              @tools.download(remote_path, local_path)
            rescue StandardError => e
              if allow_missing
                @logger.warn("Remote file not found, skipping: #{remote_path} (#{e.message})")
                next
              end
              raise
            end
            @tools.cmd("Remove-Item -Recurse -Force '#{remote_path}' -ErrorAction SilentlyContinue") if move

          else
            raise "Unknown files_action direction: #{file_op['direction']}"
          end
        end
      end

      def handle_guest_reboot(step)
        @tools.restart_and_wait
        handle_guest_run(step['post_reboot_verify']) if step['post_reboot_verify']
      end

      def handle_host_run(step)
        host_config = step['host_run']
        command = host_config['command']
        command = @context.substitute_variables(command, step['variables'] || {})

        @logger.debug("Host command: #{command}")

        output, status = if host_config['shell']
                           [`#{command} 2>&1`, $CHILD_STATUS]
                         else
                           Open3.capture2e(command)
                         end

        exit_code = status.exitstatus
        @context.set_variable(step['capture_output'], output.strip) if step['capture_output']

        expected_code = host_config['expected_exit_code'] || 0
        raise "Host command failed with exit code #{exit_code}, expected #{expected_code}" if exit_code != expected_code

        { stdout: output, exit_code: exit_code }
      end

      def handle_barrier(step)
        # No coordination needed in single-VM mode — barriers are no-ops.
        @logger.info("Barrier: #{step['barrier']} (single-VM mode)")
      end

      def validate_output(output, step)
        if step['expected_output_contains']
          expected = step['expected_output_contains']
          unless output.include?(expected)
            raise "Output validation failed: expected to contain '#{expected}'"
          end
        end

        if step['expected_output_matches']
          pattern = Regexp.new(step['expected_output_matches'])
          unless output.match?(pattern)
            raise "Output validation failed: expected to match '#{pattern}'"
          end
        end

        validate_rules(output, step['validation']) if step['validation']
      end

      def validate_rules(output, validation)
        case validation['type']
        when 'output_contains'
          expected = validation['value']
          raise validation['message'] || "Validation failed: expected '#{expected}'" unless output.include?(expected)
        else
          @logger.warn("Unknown validation type: #{validation['type']}")
        end
      end

      def handle_step_error(step, error_message)
        return if step['ignore_errors']

        raise error_message if step['fail_on_error'] != false
      end
    end
  end
end
