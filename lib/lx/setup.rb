# frozen_string_literal: true

require "lx/database"
require "lx/adminer"
require "lx/runtime"
require "lx/system"

module Lx
  class Setup
    def initialize(config:, runner: CommandRunner.new, database: nil, runtime: nil, adminer: nil, output: $stdout)
      @config = config
      @runner = runner
      @database = database || Database.new(config:, runner:)
      @runtime = runtime || Runtime.new(config)
      @adminer = adminer || Adminer.new(config:)
      @output = output
    end

    def run(skip_dependencies: false)
      @config.ensure_safe!
      validate_repositories!
      validate_commands!

      announce("Creating local runtime")
      @runtime.prepare_directories!
      @runtime.generate_local_files!
      @runtime.render_nginx!

      install_dependencies! unless skip_dependencies

      announce("Installing Adminer #{@config.adminer_version}") if @adminer.install!

      announce("Preparing development database")
      @database.prepare!(output: @output)
      announce("Setup complete")
      true
    end

    private

    def validate_repositories!
      {"ruby" => "Gemfile", "front" => "package.json"}.each do |name, marker|
        path = @config.repository(name)
        raise ConfigError, "Repository not found: #{path}" unless path.join(marker).file?
      end
    end

    def validate_commands!
      %w[ruby bundle node npm pg_isready psql].each do |command|
        raise CommandError, "Required command not found: #{command}. Run lx doctor for installation guidance." unless @runner.available?(command)
      end
    end

    def install_dependencies!
      ruby = @config.service("ruby")
      unless @runner.capture("bundle", "check", chdir: ruby.cwd).success?
        announce("Installing Ruby dependencies")
        @runner.run!("bundle", "install", chdir: ruby.cwd, output: @output)
      end

      front = @config.service("front")
      return if front.cwd.join("node_modules").directory?

      announce("Installing frontend dependencies")
      @runner.run!("npm", "install", chdir: front.cwd, output: @output)
    end

    def announce(message)
      @output.puts("==> #{message}")
    end
  end
end
