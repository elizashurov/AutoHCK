# frozen_string_literal: true

module AutoHCK
  module Functest
    # TestExecutor orchestrates test execution
    class TestExecutor
      attr_reader :results, :context

      def initialize(project, tools, default_timeout:)  
        @project = project
        @tools = tools
        @logger = project.logger
        @context = TestContext.new(project)
        @step_handler = StepHandler.new(project, tools, @context, default_timeout: default_timeout)
        @results = []
      end

      def execute_test(test)
        test_name = test['name']
        @logger.info('=' * 80)
        @logger.info("Starting test: #{test_name}")
        @logger.info("Description: #{test['description']}") if test['description']
        @logger.info('=' * 80)

        start_time = Time.now
        result = {
          name: test_name,
          description: test['description'],
          status: 'running',
          steps: [],
          start_time: start_time
        }

        begin
          test['test_steps'].each_with_index do |step, index|
            result[:steps] << execute_test_step(step, index)
          end

          result[:status] = 'passed'
          @logger.info("PASSED: #{test_name}")

        rescue StandardError => e
          result[:status] = 'failed'
          result[:error] = e.message
          @logger.error("FAILED: #{test_name} - #{e.message}")

        ensure
          run_cleanup(test)
          result[:end_time] = Time.now
          result[:duration] = result[:end_time] - start_time
          @results << result
        end

        result
      end

      def execute_tests(tests)
        @logger.info("Executing #{tests.length} test(s)")
        tests.each { |test| execute_test(test) }
        summary
      end

      def summary
        total = @results.length
        passed = @results.count { |r| r[:status] == 'passed' }
        failed = @results.count { |r| r[:status] == 'failed' }

        @logger.info('')
        @logger.info('=' * 80)
        @logger.info('TEST SUMMARY')
        @logger.info('=' * 80)
        @logger.info("Total:  #{total}")
        @logger.info("Passed: #{passed}")
        @logger.info("Failed: #{failed}")
        @logger.info('=' * 80)

        { total: total, passed: passed, failed: failed, results: @results }
      end

      private

      def execute_test_step(step, index)
        desc = @context.substitute_variables(step['desc'] || "Step #{index + 1}")
        start_time = Time.now
        step_result = { index: index, description: desc, status: 'running', start_time: start_time }

        begin
          @step_handler.execute_step(step, index)
          step_result[:status] = 'passed'
          @logger.info("  PASS: #{desc}")

        rescue StandardError => e
          step_result[:status] = 'failed'
          step_result[:error] = e.message
          @logger.error("  FAIL: #{desc} - #{e.message}")
          raise

        ensure
          step_result[:end_time] = Time.now
          step_result[:duration] = step_result[:end_time] - start_time
        end

        step_result
      end

      def run_cleanup(test)
        return unless test['cleanup']

        @logger.info('Running cleanup steps...')
        test['cleanup'].each_with_index do |step, index|
          @step_handler.execute_step(step, index)
        rescue StandardError => e
          @logger.warn("Cleanup step failed (ignoring): #{e.message}")
        end
      end
    end
  end
end
