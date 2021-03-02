# frozen_string_literal: true

require "json"
require "parallel_tests/rspec/runner"

require_relative "../utils/hash_extension"

module TurboTests
  class Runner
    using CoreExtensions

    def self.run(opts = {})
      files = opts[:files]
      formatters = opts[:formatters]
      tags = opts[:tags]

      # SEE: https://bit.ly/2NP87Cz
      start_time = opts.fetch(:start_time) { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      verbose = opts.fetch(:verbose, false)
      fail_fast = opts.fetch(:fail_fast, nil)
      count = opts.fetch(:count, nil)

      reporter = Reporter.from_config(formatters, start_time)

      new(
        reporter: reporter,
        files: files,
        tags: tags,
        verbose: verbose,
        fail_fast: fail_fast,
        count: count
      ).run
    end

    def initialize(opts)
      @reporter = opts[:reporter]
      @files = opts[:files]
      @tags = opts[:tags]
      @verbose = opts[:verbose]
      @fail_fast = opts[:fail_fast]
      @count = opts[:count]
      @load_time = 0
      @load_count = 0

      @failure_count = 0
      @runtime_log = "tmp/parallel_runtime_rspec.log"

      @messages = Queue.new
      @threads = []
    end

    def run
      @num_processes = [
        ParallelTests.determine_number_of_processes(@count),
        ParallelTests::RSpec::Runner.tests_with_size(@files, {}).size
      ].min

      tests_in_groups =
        ParallelTests::RSpec::Runner.tests_in_groups(
          @files,
          @num_processes,
          runtime_log: @runtime_log
        )

      report_number_of_tests(tests_in_groups)

      tests_in_groups.each_with_index do |tests, process_id|
        start_regular_subprocess(tests, process_id + 1)
      end

      handle_messages

      @reporter.finish

      @threads.each(&:join)

      @reporter.failed_examples.empty?
    end

    protected

    def start_regular_subprocess(tests, process_id)
      start_subprocess(
        {"TEST_ENV_NUMBER" => process_id.to_s},
        @tags.map { |tag| "--tag=#{tag}" },
        tests,
        process_id
      )
    end

    def start_subprocess(env, extra_args, tests, process_id)
      if tests.empty?
        @messages << {
          "type" => "exit",
          "process_id" => process_id
        }
      else
        require "securerandom"
        env["RSPEC_FORMATTER_OUTPUT_ID"] = SecureRandom.uuid
        env["RUBYOPT"] = "-I#{File.expand_path("..", __dir__)}"

        command = [
          ENV["BUNDLE_BIN_PATH"], "exec", "rspec",
          *extra_args,
          "--seed", rand(2**16).to_s,
          "--format", "ParallelTests::RSpec::RuntimeLogger",
          "--out", @runtime_log,
          "--format", "TurboTests::JsonRowsFormatter",
          *tests
        ]

        if @verbose
          command_str = [
            env.map { |k, v| "#{k}=#{v}" }.join(" "),
            command.join(" ")
          ].select { |x| x.size > 0 }.join(" ")

          STDERR.puts "Process #{process_id}: #{command_str}"
        end

        _stdin, stdout, stderr, _wait_thr = Open3.popen3(env, *command)

        @threads <<
          Thread.new {
            require "json"
            stdout.each_line do |line|
              result = line.split(env["RSPEC_FORMATTER_OUTPUT_ID"])

              output = result.shift
              STDOUT.print(output) unless output.empty?

              message = result.shift
              next unless message

              message = JSON.parse(message)
              message["process_id"] = process_id
              @messages << message
            end

            @messages << {"type" => "exit", "process_id" => process_id}
          }

        @threads << start_copy_thread(stderr, STDERR)
      end
    end

    def start_copy_thread(src, dst)
      Thread.new do
        loop do
          msg = src.readpartial(4096)
        rescue EOFError
          break
        else
          dst.write(msg)
        end
      end
    end

    def handle_messages
      exited = 0

      loop do
        message = @messages.pop
        case message["type"]
        when "example_passed"
          example = FakeExample.from_obj(message["example"])
          @reporter.example_passed(example)
        when "group_started"
          @reporter.group_started(message["group"].to_struct)
        when "group_finished"
          @reporter.group_finished
        when "example_pending"
          example = FakeExample.from_obj(message["example"])
          @reporter.example_pending(example)
        when "load_summary"
          message = message["summary"]
          # NOTE: notifications order and content is not guaranteed hence the fetch
          #       and count increment tracking to get the latest accumulated load time
          @reporter.load_time = message["load_time"] if message.fetch("count", 0) > @load_count
        when "example_failed"
          example = FakeExample.from_obj(message["example"])
          @reporter.example_failed(example)
          @failure_count += 1
          if fail_fast_met
            @threads.each(&:kill)
            break
          end
        when "seed"
        when "close"
        when "exit"
          exited += 1
          if exited == @num_processes
            break
          end
        else
          warn("Unhandled message in main process: #{message}")
        end
      end
    rescue Interrupt
    end

    def fail_fast_met
      !@fail_fast.nil? && @fail_fast >= @failure_count
    end

    private

    def report_number_of_tests(groups)
      name = ParallelTests::RSpec::Runner.test_file_name

      num_processes = groups.size
      num_tests = groups.map(&:size).sum
      tests_per_process = (num_processes == 0 ? 0 : num_tests / num_processes)

      puts "#{num_processes} processes for #{num_tests} #{name}s, ~ #{tests_per_process} #{name}s per process"
    end
  end
end
