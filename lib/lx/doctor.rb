# frozen_string_literal: true

require "pathname"

require "lx/database"
require "lx/system"

module Lx
  class Doctor
    Check = Data.define(:label, :ok, :detail, :help)
    COMMANDS = {
      "Ruby" => ["ruby", "--version"],
      "Bundler" => ["bundle", "--version"],
      "Node.js" => ["node", "--version"],
      "npm" => ["npm", "--version"],
      "PostgreSQL" => ["psql", "--version"],
      "nginx" => ["nginx", "-v"],
      "ffmpeg" => ["ffmpeg", "-version"],
      "mailpit" => ["mailpit", "--version"]
    }.freeze
    INSTALL_HELP = {
      "nginx" => "Install nginx manually (macOS: brew install nginx, Ubuntu: sudo apt install nginx).",
      "ffmpeg" => "Install ffmpeg manually (macOS: brew install ffmpeg, Ubuntu: sudo apt install ffmpeg).",
      "mailpit" => "Install Mailpit manually: https://mailpit.axllent.org/docs/install/",
      "PostgreSQL" => "Install PostgreSQL client tools and start your local PostgreSQL service.",
      "Ruby" => "Install the Ruby version in .ruby-version with your preferred version manager.",
      "Bundler" => "Install Bundler for the Ruby version in .ruby-version.",
      "Node.js" => "Install a Node.js version compatible with mitsubachi-front.",
      "npm" => "Install npm with Node.js."
    }.freeze

    def initialize(config:, runner: CommandRunner.new, database: nil)
      @config = config
      @runner = runner
      @database = database || Database.new(config:, runner:)
    end

    def checks
      command_checks + repository_checks + database_checks + [storage_check]
    end

    def healthy?
      checks.all?(&:ok)
    end

    private

    def command_checks
      COMMANDS.map do |label, command|
        executable = command.first
        unless @runner.available?(executable)
          next Check.new(label, false, "not found", INSTALL_HELP.fetch(label))
        end

        result = @runner.capture(*command)
        version = [result.stdout, result.stderr].join(" ").lines.first.to_s.strip
        Check.new(label, true, version.empty? ? "available" : version, nil)
      end
    end

    def repository_checks
      markers = {"ruby" => "Gemfile", "front" => "package.json", "infra" => "README.md"}
      markers.map do |name, marker|
        path = @config.repository(name)
        ok = path.directory? && path.join(marker).file?
        Check.new("Repository: mitsubachi-#{name}", ok, ok ? path.to_s : "missing at #{path}", "Set MITSUBACHI_#{name.upcase}_ROOT in .env.local.")
      end
    end

    def database_checks
      reachable = @runner.available?("pg_isready") && @database.server_reachable?
      exists = reachable && @runner.available?("psql") && @database.database_exists?
      [
        Check.new("Database: PostgreSQL reachable", reachable, reachable ? "reachable" : "unreachable", "Start your existing local PostgreSQL service."),
        Check.new("Database: #{@config.database_name}", exists, exists ? "exists" : "missing", "Run lx setup to create it safely.")
      ]
    end

    def storage_check
      path = @config.runtime_root.join("storage")
      if path.directory?
        Check.new("Storage", path.writable?, path.writable? ? "writable at #{path}" : "not writable at #{path}", "Fix local directory permissions.")
      else
        parent = existing_parent(path)
        Check.new("Storage", false, "not initialized", "Run lx setup (parent #{parent} must be writable).")
      end
    end

    def existing_parent(path)
      current = path
      current = current.parent until current.exist? || current.root?
      current
    end
  end
end
