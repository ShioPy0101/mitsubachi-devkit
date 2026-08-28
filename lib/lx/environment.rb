# frozen_string_literal: true

require "lx/runtime"
require "lx/system"

module Lx
  class Environment
    def initialize(config:, runner: CommandRunner.new, process_manager:, database:, output: $stdout)
      @config = config
      @runner = runner
      @process_manager = process_manager
      @database = database
      @runtime = Runtime.new(config)
      @output = output
    end

    def start
      @config.ensure_safe!
      validate_repositories!
      validate_commands!
      @runtime.prepare_directories!
      @runtime.render_nginx!
      validate_nginx!

      existing = @process_manager.statuses.to_h { |status| [status.name, status] }
      existing.each_value { |status| print_start_status(status) if %i[running unhealthy].include?(status.state) }

      @output.puts("==> Preparing development database")
      @database.prepare!(output: @output)

      started_here = []
      @config.managed_service_names.map do |name|
        if %i[running unhealthy].include?(existing.fetch(name).state)
          existing.fetch(name)
        else
          status = @process_manager.start(name)
          started_here << name
          print_start_status(status)
          status
        end
      end
    rescue Error
      started_here&.reverse_each { |name| safely_stop(name) }
      raise
    end

    private

    def validate_repositories!
      {"ruby" => "Gemfile", "front" => "package.json"}.each do |name, marker|
        path = @config.repository(name)
        raise ConfigError, "Repository not found: #{path}" unless path.join(marker).file?
      end
    end

    def validate_commands!
      missing = @config.required_commands.reject { |command| @runner.available?(command) }
      @config.services.each_value do |service|
        executable = service.command.first
        missing << executable unless @runner.available?(executable, cwd: service.cwd)
      end
      return if missing.uniq.empty?

      raise CommandError, "Required command(s) not found: #{missing.uniq.join(', ')}. Run lx doctor for installation guidance."
    end

    def validate_nginx!
      service = @config.service("nginx")
      command = service.command
      prefix = command.fetch(command.index("-p") + 1)
      config_path = command.fetch(command.index("-c") + 1)
      result = @runner.capture(command.first, "-t", "-p", prefix, "-c", config_path)
      return if result.success?

      detail = [result.stdout, result.stderr].join("\n").strip
      raise CommandError, "nginx config error: #{detail}"
    end

    def print_start_status(status)
      detail = status.detail == "started" ? "started (PID #{status.pid})" : "already running (PID #{status.pid})"
      @output.puts(format("%-10s %s", status.name, detail))
    end

    def safely_stop(name)
      @process_manager.stop(name)
    rescue Error => error
      @output.puts("warning: failed to roll back #{name}: #{error.message}")
    end
  end
end
