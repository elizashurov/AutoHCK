# frozen_string_literal: true

module AutoHCK
  class HCKTest
    # Prepares fresh client overlays against the exclusively owned, persistent DC.
    # A restored member is verified, never silently repaired by resetting its AD account.
    class DomainPreparation
      class PreparationError < AutoHCKError; end

      SCRIPT_DIR = File.expand_path('domain', __dir__)
      WINRM_OPTIONS = Tools::DOMAIN_CLIENT_WINRM_OPTIONS.merge(
        operation_timeout: 20, receive_timeout: 30, retry_limit: 1
      ).freeze

      def self.validate_configuration!(project)
        %w[domain_username domain_password windows_username windows_password].each do |key|
          next if project.config[key].is_a?(String) && !project.config[key].empty?

          raise InvalidConfigFile, "Domain preparation requires #{key} in config.json (or its host override)"
        end
        user = project.config.fetch('domain_username')
        return if user.include?('\\') || user.include?('@')

        raise InvalidConfigFile, 'domain_username must be domain-qualified, for example SVVP\\Administrator'
      end

      def initialize(project, client_names, runner)
        self.class.validate_configuration!(project)
        @project = project
        @logger = project.logger
        @config = project.engine_platform.domain_controller
        @runner = runner
        @clients = project.engine_platform.clients.values.to_h { |client| [client.name, client] }
        @join_attempted = []
        validate_clients!(client_names)
        @tools = Tools.new(project, no_studio: true, clients_addrs: endpoints)
      end

      def prepare!
        @logger.info('Preparing domain clients under exclusive persistent DC ownership')
        wait_for('authenticated DC readiness') do
          run_script(@config.name, 'dc_ready', credentials: true)['ready'] == true
        end
        states = client_states
        @clients.each_key { |name| run_script(name, 'client_dns') }
        states.each do |name, state|
          join_client(name) unless state.fetch('member')
          verify_client(name)
        end
      end

      def verify!(studio)
        @clients.each_key { |name| verify_client(name) }
        wait_for('HLK clients Ready') { pool_ready?(studio.list_pools) }
        @logger.info("Domain preparation complete: #{@clients.keys.join(', ')} verified and Ready in HLK")
      end

      def close
        @tools.close
      end

      private

      def client_states
        states = @clients.to_h do |name, _client|
          [name, wait_for("#{name} authenticated WinRM") { run_script(name, 'client_state') }]
        end
        # Check every endpoint before changing DNS or removing any AD account.
        states.each { |name, state| validate_state!(name, state) }
        states
      end

      def validate_clients!(started_names)
        valid_names = @clients.keys.all? { |name| /\A[a-zA-Z0-9][a-zA-Z0-9-]{0,14}\z/.match?(name) }
        unique_names = @clients.keys.map(&:downcase).uniq.size == @clients.size
        return if valid_names && unique_names && !@clients.empty? && started_names.sort == @clients.keys.sort

        raise InvalidConfigFile, 'Domain preparation requires all configured clients with unique Windows hostnames'
      end

      def endpoints
        addresses = @clients.to_h do |name, client|
          [name, { addr: client.winrm_addr, port: client.winrm_port,
                   user: Tools.local_username(name, @project.config.fetch('windows_username')),
                   winrm_options: WINRM_OPTIONS }]
        end
        addresses[@config.name] = {
          addr: @config.ip, port: @config.winrm_port,
          user: @project.config.fetch('domain_username'), pass: @project.config.fetch('domain_password'),
          winrm_options: WINRM_OPTIONS
        }
        addresses
      end

      def validate_state!(name, state)
        unless state.fetch('name').casecmp?(name)
          raise PreparationError, "WinRM endpoint for #{name} returned a different hostname"
        end
        return if state['member'] == true && state.fetch('domain').casecmp?(@config.domain)
        return if state['member'] == false && !@project.restored? && !@join_attempted.include?(name)

        raise PreparationError,
              "#{name} has unexpected domain membership. Start a fresh session; AD accounts are unchanged."
      end

      def join_client(name)
        # A failed Add-Computer or reboot can leave an AD account while the
        # guest still reports workgroup membership. Never delete it on a retry
        # against the same overlay; the next fresh session gets new overlays.
        @join_attempted << name
        @logger.info("#{name}: checking/removing only its matching stale AD computer account")
        run_script(@config.name, 'remove_account', client_name: name, credentials: true)
        @logger.info("#{name}: joining #{@config.domain}")
        run_script(name, 'join', credentials: true)
        verify_ownership!
        @tools.restart_machine_and_wait(name, timeout: @config.readiness_timeout)
      end

      def verify_client(name)
        wait_for("#{name} domain membership, DNS and secure channel") do
          run_script(name, 'client_verify')['verified'] == true
        end
        @logger.info("#{name}: domain membership, control DNS, DC discovery and secure channel verified")
      end

      def pool_ready?(pools)
        pool = pools.find { |entry| entry['name'] == @project.engine_tag }
        return false unless pool

        machines = pool.fetch('machines')
        pool_members_match?(machines) && machines.all? { |machine| machine['state'] == 'Ready' }
      end

      def pool_members_match?(machines)
        expected = @clients.keys.map(&:downcase).sort
        actual = machines.map { |machine| machine.fetch('name').downcase }.sort
        unless (actual - expected).empty?
          raise PreparationError, 'HLK test pool contains unexpected machines; the DC must not be an HLK client'
        end

        actual == expected
      end

      def verify_ownership!
        return if @runner&.alive?

        raise PreparationError, 'Persistent DC is not running under this session; domain preparation stopped'
      end

      def wait_for(description)
        @logger.info("Waiting for #{description} (up to #{@config.readiness_timeout}s)")
        Timeout.timeout(@config.readiness_timeout) do
          loop do
            verify_ownership!
            begin
              result = yield
              return result if result
            rescue Tools::ToolsHCKError => e
              @logger.debug("#{description}: #{e.message}")
            end
            sleep 5
          end
        end
      rescue Timeout::Error
        raise PreparationError,
              "Timed out waiting for #{description}; inspect Windows event logs before starting a new run"
      end

      def ps_literal(value)
        "'#{value.gsub("'", "''")}'"
      end

      def script_variables(client_name)
        {
          'dcName' => @config.name, 'dcIP' => @config.ip, 'domain' => @config.domain,
          'clientName' => client_name, 'controlIP' => @clients[client_name]&.winrm_addr.to_s
        }.map { |key, value| "$#{key} = #{ps_literal(value)}" }.join("\n") +
          "\n$allowedClients = @(#{@clients.keys.map { |name| ps_literal(name) }.join(', ')})\n"
      end

      def credential_variables
        [
          "$domainUser = #{ps_literal(@project.config.fetch('domain_username'))}",
          "$domainPassword = #{ps_literal(@project.config.fetch('domain_password'))}",
          File.read(File.join(SCRIPT_DIR, 'credential.ps1'))
        ].join("\n")
      end

      def run_script(machine, script, client_name: machine, credentials: false)
        verify_ownership!
        command = "$ErrorActionPreference = 'Stop'\n#{script_variables(client_name)}"
        command += credential_variables if credentials
        command += File.read(File.join(SCRIPT_DIR, "#{script}.ps1"))
        output = Timeout.timeout(@config.readiness_timeout) do
          @tools.run_on_machine(machine, "domain #{script}", command, retry_on_failure: false, sensitive: true)
        end
        JSON.parse(output)
      rescue Timeout::Error, JSON::ParserError
        raise PreparationError, "#{machine}: domain #{script} did not return a valid result; command was not retried"
      end
    end
  end
end
