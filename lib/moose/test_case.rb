require_relative 'harness'
require_relative 'browser'
require_relative 'test_status'
require_relative 'test_case/all'
require_relative "utilities"
require 'rspec/expectations'

module Moose
  class TestCase
    class NoTestBlock < StandardError; end
    class ShortCircuit < StandardError; end
    include TestStatus
    include Utilities::Inspectable
    include RSpec::Matchers
    inspector(:file)

    status_method :result
    attr_accessor :test_block, :start_time, :end_time, :result, :exception, :has_run
    attr_reader :file, :extra_metadata, :test_group, :moose_configuration

    def initialize(file:, test_group:, moose_configuration:, extra_metadata: {})
      @file = file
      @test_group = test_group
      @moose_configuration = moose_configuration
      @extra_metadata = Hash[extra_metadata] || {}
    end

    def build
      Moose.load_test_case_from_file(file: file, test_case: self)
    end

    def base_url
      test_group.test_suite.configuration.base_url
    end

    def browser(index: nil, options: {})
      if index
        browsers[index]
      elsif last_browser = browsers.last
        last_browser
      else
        new_browser(**options)
      end
    end

    def new_browser(test_suite: test_group.test_suite, **opts)
      browser_instance = Moose::Browser::Instance.new(
        test_suite: test_suite,
        test_case: self,
        browser_options: opts
      )
      browsers << browser_instance
      browser_instance
    end

    def run!(opts={})
      self.start_time = Time.now
      begin
        raise NoTestBlock unless test_block
        Moose.msg.banner("Running Test Case: #{trimmed_filepath}")
        moose_configuration.run_test_case_with_hooks(test_case: self, on_error: :fail_with_exception) do
          test_group.test_suite.configuration.run_test_case_with_hooks(test_case: self, on_error: :fail_with_exception) do
            test_group.configuration.call_hooks_with_entity(entity: self, on_error: :fail_with_exception) do
              begin
                result = catch(:short_circuit) do
                  instance_eval(&test_block)
                end
                pass_or_result!(result)
              ensure
                self.end_time = Time.now
              end
            end
          end
        end
      rescue Exception => e
        fail_with_exception(e)
      ensure
        self.has_run = true
        teardown
        self.end_time = Time.now
        reporter.report!
        self
      end
    end

    def remove_browser(b)
      b.close!
      browsers.delete(b)
    end

    def run_as(suite, opts={}, &block)
      Moose::Harness.run_as(current_test: self, suite: suite, opts: opts, &block)
    end

    def browsers
      @browsers ||= []
    end

    def keywords
      extra_metadata.fetch("keywords", {})
    end

    def trimmed_filepath
      @trimmed_filepath ||= Utilities::FileUtils.trim_filename(file)
    end

    def final_report!(opts = {})
      return unless has_run
      reporter.final_report!
    end

    def time_elapsed
      return unless end_time && start_time
      end_time - start_time
    end

    def metadata
      starting_metadata = [:time_elapsed,:result,:start_time,:end_time,:file,:exception,:keywords].inject({}) do |memo, method|
        begin
          memo.merge!(method => send(method))
          memo
        rescue => e
          # drop error for now
          memo
        end
      end
      starting_metadata.merge(extra_metadata).merge(
        :test_group => test_group.metadata
      )
    end

    def rerun_script
      reporter.rerun_script
    end

    private

    def short_circuit!(status, msg="short circuit")
      found_status = find_result_status(status)
      raise ArgumentError, "#{status} not found in #{POSSIBLE_RESULTS}" unless found_status
      if found_status == self.class::FAIL
        raise ShortCircuit, msg
      else
        Moose.msg.send(status, msg)
        throw :short_circuit, found_status
      end
    end

    def fail_with_exception(err)
      self.exception = err
      fail!
    end

    def reporter
      @reporter ||= Reporter.new(self)
    end

    def teardown
      remove_browsers
    end

    def remove_browsers
      browsers.each do |b|
        remove_browser(b)
      end
    end
  end
end
