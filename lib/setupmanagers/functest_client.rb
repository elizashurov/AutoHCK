# frozen_string_literal: true

require_relative '../engines/functest/functest_tools'

module AutoHCK
  # FunctestClient: setup manager for the functest engine.
  # phase (wait for WinRM, install drivers, install extra software).
  #
  # HCKClient gets its transport (@tools) from @studio.tools after the HLK
  # controller is up.  FunctestClient creates FunctestTools directly from the
  # VM's world IP because there is no studio in the functest flow.
  class FunctestClient
    attr_reader :name, :tools

    def initialize(setup_manager, scope, name, run_opts = nil)
      @project = setup_manager.project
      @logger = @project.logger
      @setup_manager = setup_manager
      @name = name
      @logger.info("Starting functest client #{name}")
      @runner = setup_manager.run_client(scope, name, run_opts)
      scope << self
    end

    # Mirrors HCKClient#prepare_machine.
    # Creates the WinRM transport then installs extra software and drivers in
    # the same before/after order that hcktest uses.
    def prepare_machine
      @logger.info("Preparing client #{@name}...")
      @tools = build_tools
      @project.extra_sw_manager.install_extra_software_on_functest_client_before_driver(@tools)
      install_drivers
      @project.extra_sw_manager.install_extra_software_on_functest_client_after_driver(@tools)
    end

    def close
      @logger.info("Exiting FunctestClient #{@name}")
    end

    private

    def build_tools
      world_ip = wait_for_world_ip
      Functest::FunctestTools.new(
        world_ip,
        @project.config['windows_username'],
        @project.config['windows_password'],
        @logger,
        port: @project.config['ssh_port'] || Functest::FunctestTools::SSH_DEFAULT_PORT
      )
    end

    def wait_for_world_ip
      @logger.info("Waiting for client VM #{@name} to get world IP...")
      ip = nil
      sleep 5 until (ip = @setup_manager.find_client_world_ip(@name))
      @logger.info("Client VM #{@name} world IP: #{ip}")
      ip
    end

    def install_drivers
      driver_path = @project.options.test.driver_path
      drivers = @project.engine.drivers
      return if driver_path.nil? || drivers.empty?

      @logger.info('Installing drivers on client VM...')
      drivers.each do |driver|
        if driver.install_method == Models::DriverInstallMethods::NoDrviver
          @logger.info("Driver installation skipped for #{driver.name}")
          next
        end

        @logger.info("Installing #{driver.name} (#{driver.inf}) via #{driver.install_method}")
        @tools.install_driver_package(
          driver.install_method.to_s,
          driver_path,
          driver.inf,
          custom_cmd: driver.install_command,
          sys_file: driver.sys,
          force_install_cert: driver.install_cert
        )
      end
    end
  end
end
