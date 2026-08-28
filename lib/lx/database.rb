# frozen_string_literal: true

require "uri"

require "lx"
require "lx/system"

module Lx
  class Database
    def initialize(config:, runner: CommandRunner.new)
      @config = config
      @runner = runner
    end

    def server_reachable?
      @runner.capture("pg_isready", "-d", admin_url).success?
    end

    def database_exists?
      @runner.capture("psql", @config.database_url, "-Atqc", "SELECT 1").success?
    end

    def prepare!(output: $stdout)
      raise CommandError, "PostgreSQL is not reachable at #{admin_url}" unless server_reachable?

      ruby = @config.service("ruby")
      @runner.run!(
        "bin/rails", "db:prepare",
        env: @config.local_environment.merge(ruby.env),
        chdir: ruby.cwd,
        output:
      )
    end

    private

    def admin_url
      uri = URI.parse(@config.database_url)
      uri.path = "/postgres"
      uri.to_s
    end
  end
end
