# frozen_string_literal: true

module AutoHCK
  module Functest
    # TestContext holds runtime state for test execution
    class TestContext
      attr_reader :variables, :logger, :project

      def initialize(project)
        @project = project
        @logger = project.logger
        @variables = {}
        @start_time = Time.now
      end

      # Store a captured output variable
      def set_variable(name, value)
        @logger.debug("Setting variable '#{name}' = '#{value}'")
        @variables[name] = value
      end

      # Get a variable value
      def get_variable(name)
        @variables[name]
      end

      # Substitute variables in a string
      # Example: "ping @SUPPORT_IP@" with variables["SUPPORT_IP"] = "192.168.1.10"
      # Returns: "ping 192.168.1.10"
      def substitute_variables(text, step_variables = {})
        result = text.dup

        # First apply step-level variable mappings
        step_variables.each do |placeholder, var_name|
          value = get_variable(var_name)
          if value.nil?
            @logger.warn("Variable '#{var_name}' not found for placeholder '#{placeholder}'")
            next
          end
          result.gsub!(placeholder, value.to_s)
        end

        # Then apply direct @VAR@ substitutions from context
        result.gsub!(/@(\w+)@/) do |match|
          var_name = Regexp.last_match(1)
          value = get_variable(var_name)
          if value.nil?
            @logger.warn("Variable '#{var_name}' not found in context")
            match # Keep original if not found
          else
            value.to_s
          end
        end

        result
      end

      def elapsed_time
        Time.now - @start_time
      end
    end
  end
end
