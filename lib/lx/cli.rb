# frozen_string_literal: true

require "pathname"

require "lx/config"
require "lx/database"
require "lx/doctor"
require "lx/environment"
require "lx/process_manager"
require "lx/setup"
require "lx/system"

module Lx
  class CLI
    def initialize(argv, root: Pathname(__dir__).join("../..").expand_path, output: $stdout, error: $stderr,
                   runner: CommandRunner.new)
      @argv = argv.dup
      @root = Pathname(root)
      @output = output
      @error = error
      @runner = runner
    end

    def run
      command = @argv.shift
      return print_help(0) if [nil, "help", "--help", "-h"].include?(command)

      case command
      when "doctor" then doctor
      when "setup" then setup
      when "pm" then process_command
      else
        @error.puts("Unknown command: #{command}")
        print_help(2)
      end
    rescue Error, KeyError, ArgumentError => error
      @error.puts("lx: #{error.message}")
      1
    rescue Interrupt
      @error.puts("lx: interrupted")
      130
    end

    private

    def config
      @config ||= Config.new(root: @root)
    end

    def database
      @database ||= Database.new(config:, runner: @runner)
    end

    def process_manager
      @process_manager ||= ProcessManager.new(config:)
    end

    def doctor
      reject_arguments!("doctor")
      @output.puts("Mitsubachi DevKit Doctor\n")
      checks = Doctor.new(config:, runner: @runner, database:).checks
      checks.each do |check|
        @output.puts("#{check.ok ? '✓' : '✗'} #{check.label}: #{check.detail}")
        @output.puts("  #{check.help}") if !check.ok && check.help
      end
      @output.puts(checks.all?(&:ok) ? "\nEnvironment is ready." : "\nEnvironment needs attention. No packages were installed.")
      checks.all?(&:ok) ? 0 : 1
    end

    def setup
      skip_dependencies = @argv.delete("--skip-dependencies")
      reject_arguments!("setup")
      Setup.new(config:, runner: @runner, database:, output: @output).run(skip_dependencies: !!skip_dependencies)
      0
    end

    def process_command
      action = @argv.shift
      case action
      when "start" then pm_start
      when "stop" then pm_stop
      when "restart" then pm_restart
      when "status" then pm_status
      when "logs" then pm_logs
      when nil, "help", "--help", "-h" then print_pm_help(0)
      else
        @error.puts("Unknown pm command: #{action}")
        print_pm_help(2)
      end
    end

    def pm_start
      reject_arguments!("pm start")
      statuses = Environment.new(
        config:,
        runner: @runner,
        process_manager:,
        database:,
        output: @output
      ).start
      statuses.all? { |status| status.state == :running } ? 0 : 1
    end

    def pm_stop
      reject_arguments!("pm stop")
      process_manager.stop_all.each { |status| @output.puts(format("%-10s %s", status.name, status.detail)) }
      0
    end

    def pm_restart
      reject_arguments!("pm restart")
      process_manager.stop_all.each { |status| @output.puts(format("%-10s %s", status.name, status.detail)) }
      pm_start
    end

    def pm_status
      reject_arguments!("pm status")
      statuses = process_manager.statuses
      postgres = database.server_reachable?
      @output.puts("Mitsubachi Local Environment\n")
      @output.puts(format("%-12s %-12s %s", "SERVICE", "STATUS", "PID"))
      statuses.each { |status| @output.puts(format("%-12s %-12s %s", status.name, status.state, status.pid || "-")) }
      @output.puts(format("%-12s %-12s %s", "postgres", postgres ? "available" : "unavailable", "-"))
      print_urls
      statuses.all? { |status| status.state == :running } && postgres ? 0 : 1
    end

    def pm_logs
      name = @argv.shift
      reject_arguments!("pm logs")
      paths = if name
                [config.service(name).log_path]
              else
                config.managed_service_names.map { |service_name| config.service(service_name).log_path }
              end
      existing = paths.select(&:file?)
      raise CommandError, "No logs found. Start the environment first." if existing.empty?

      Kernel.exec("tail", "-n", "100", "-f", *existing.map(&:to_s))
    end

    def print_urls
      @output.puts("\nFrontend:\n  http://127.0.0.1:3000")
      @output.puts("\nLocal proxy / file delivery:\n  http://127.0.0.1:8080")
      @output.puts("\nAPI (direct):\n  http://127.0.0.1:3001")
      @output.puts("\nMailpit:\n  http://127.0.0.1:8025")
    end

    def reject_arguments!(command)
      return if @argv.empty?

      raise ConfigError, "Unexpected argument(s) for #{command}: #{@argv.join(' ')}"
    end

    def print_help(code)
      @output.puts <<~HELP
        Usage: lx <command>

          setup              Initialize local files, dependencies, and database
          doctor             Diagnose the development environment without changing it
          pm <command>       Start, stop, restart, inspect, or view service logs
      HELP
      code
    end

    def print_pm_help(code)
      @output.puts <<~HELP
        Usage: lx pm <command>

          start              Start all local services idempotently
          stop               Stop only services started by this devkit
          restart            Stop and start managed services
          status             Show service and PostgreSQL status
          logs [service]     Follow all logs or one service log
      HELP
      code
    end
  end
end
