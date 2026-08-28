# frozen_string_literal: true

require "pathname"
require "yaml"
require "uri"

require "lx"

module Lx
  class Config
    REPOSITORY_KEYS = %w[ruby front infra].freeze
    PRODUCTION_HOST_PATTERNS = [/(^|\.)shiosalt\.com\z/i, /production/i, /prod[.-]/i].freeze

    attr_reader :root, :data, :local_env

    def initialize(root:, env: ENV, config_path: nil, local_config_path: nil, env_path: nil)
      @root = Pathname(root).expand_path
      @env = env
      @local_env = load_env_file(env_path || @root.join(".env.local"))
      @context = build_context
      defaults = load_yaml(config_path || @root.join("config/devkit.yml"))
      overrides = load_yaml(local_config_path || @root.join("config/local.yml"), optional: true)
      @data = expand_values(deep_merge(defaults, overrides || {}))
      validate!
    end

    def runtime_root
      Pathname(fetch("runtime", "root")).expand_path
    end

    def repository(name)
      Pathname(fetch("repositories", name.to_s)).expand_path
    end

    def repositories
      REPOSITORY_KEYS.to_h { |name| [name, repository(name)] }
    end

    def services
      fetch("services").map do |name, definition|
        [name, Service.new(name, definition, self)]
      end.to_h
    end

    def service(name)
      services.fetch(name.to_s) { raise ConfigError, "Unknown service: #{name}" }
    end

    def database_url
      fetch("database", "url")
    end

    def database_name
      fetch("database", "name")
    end

    def managed_service_names
      fetch("startup_order")
    end

    def required_commands
      fetch("required_commands")
    end

    def adminer_version
      fetch("adminer", "version").to_s
    end

    def adminer_url
      fetch("adminer", "url")
    end

    def adminer_sha256
      fetch("adminer", "sha256")
    end

    def health_timeout
      Integer(data.fetch("health_timeout", 30))
    end

    def stop_timeout
      Integer(data.fetch("stop_timeout", 10))
    end

    def local_environment
      @local_env.merge(
        "DEVKIT_ROOT" => root.to_s,
        "MITSUBACHI_RUBY_ROOT" => repository("ruby").to_s,
        "MITSUBACHI_FRONT_ROOT" => repository("front").to_s,
        "MITSUBACHI_INFRA_ROOT" => repository("infra").to_s,
        "MITSUBACHI_RUNTIME_ROOT" => runtime_root.to_s,
        "DATABASE_URL" => database_url
      )
    end

    def ensure_safe!
      env = services.values.reduce(local_environment) { |all, service| all.merge(service.env) }
      [@env.to_h, @local_env].each { |candidate| check_supplied_environment!(candidate) }
      rails_env = env.fetch("RAILS_ENV", "development")
      refuse!("RAILS_ENV=#{rails_env}") unless rails_env == "development"

      check_database!(env.fetch("DATABASE_URL", database_url))
      check_storage!(env.fetch("FILE_STORAGE_ROOT", runtime_root.join("storage").to_s))
      check_mail!(env)
      check_hosts!(env)
      true
    end

    def fetch(*keys)
      keys.reduce(data) do |current, key|
        current.fetch(key.to_s) { raise ConfigError, "Missing config key: #{keys.join('.')}" }
      end
    end

    private

    def validate!
      REPOSITORY_KEYS.each { |name| fetch("repositories", name) }
      fetch("database", "url")
      fetch("database", "name")
      fetch("adminer", "version")
      fetch("adminer", "url")
      fetch("adminer", "sha256")
      fetch("services")
      fetch("startup_order").each { |name| service_definition(name) }
    end

    def service_definition(name)
      fetch("services").fetch(name.to_s) { raise ConfigError, "startup_order references unknown service: #{name}" }
    end

    def build_context
      parent = root.parent
      values = @env.to_h.merge(@local_env)
      values.merge(
        "DEVKIT_ROOT" => root.to_s,
        "RUNTIME_ROOT" => root.join("runtime").to_s,
        "RUBY_ROOT" => values.fetch("MITSUBACHI_RUBY_ROOT", parent.join("mitsubachi-ruby").to_s),
        "FRONT_ROOT" => values.fetch("MITSUBACHI_FRONT_ROOT", parent.join("mitsubachi-front").to_s),
        "INFRA_ROOT" => values.fetch("MITSUBACHI_INFRA_ROOT", parent.join("mitsubachi-infra").to_s)
      )
    end

    def load_env_file(path)
      pathname = Pathname(path)
      return {} unless pathname.file?

      pathname.each_line.with_object({}) do |line, values|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        key, value = stripped.split("=", 2)
        raise ConfigError, "Invalid .env.local line: #{stripped}" unless key&.match?(/\A[A-Z][A-Z0-9_]*\z/) && value

        values[key] = unquote(value.strip)
      end
    end

    def unquote(value)
      return value[1...-1] if value.length >= 2 && ["'", '"'].include?(value[0]) && value[-1] == value[0]

      value
    end

    def load_yaml(path, optional: false)
      pathname = Pathname(path)
      return nil if optional && !pathname.file?
      raise ConfigError, "Config file not found: #{pathname}" unless pathname.file?

      parsed = YAML.safe_load(pathname.read, permitted_classes: [], permitted_symbols: [], aliases: false)
      parsed.is_a?(Hash) ? parsed : raise(ConfigError, "Config root must be a mapping: #{pathname}")
    rescue Psych::Exception => error
      raise ConfigError, "Invalid YAML in #{pathname}: #{error.message}"
    end

    def deep_merge(base, override)
      base.merge(override) do |_key, left, right|
        left.is_a?(Hash) && right.is_a?(Hash) ? deep_merge(left, right) : right
      end
    end

    def expand_values(value)
      case value
      when Hash then value.to_h { |key, item| [key.to_s, expand_values(item)] }
      when Array then value.map { |item| expand_values(item) }
      when String then value.gsub(/\$\{([A-Z][A-Z0-9_]*)\}/) { @context.fetch(Regexp.last_match(1)) { raise ConfigError, "Unknown variable: #{Regexp.last_match(1)}" } }
      else value
      end
    end

    def check_database!(value)
      uri = URI.parse(value)
      database = uri.path.to_s.delete_prefix("/")
      refuse!("database #{database.inspect}") unless database == database_name && database.end_with?("_development")
      refuse!("database host #{uri.host}") if uri.host && !uri.host.empty? && !local_host?(uri.host)
    rescue URI::InvalidURIError
      raise SafetyError, "Refusing to start: invalid DATABASE_URL."
    end

    def check_supplied_environment!(env)
      refuse!("RAILS_ENV=#{env['RAILS_ENV']}") if env["RAILS_ENV"] && env["RAILS_ENV"] != "development"
      check_database!(env["DATABASE_URL"]) if env["DATABASE_URL"]
      check_storage!(env["FILE_STORAGE_ROOT"]) if env["FILE_STORAGE_ROOT"]
      check_mail!(env) if env["SMTP_ADDRESS"] || env["SMTP_AUTHENTICATION"]
      check_hosts!(env)
    end

    def check_storage!(value)
      storage = Pathname(value).expand_path
      expected = runtime_root.join("storage").expand_path
      refuse!("storage path #{storage}") unless storage == expected || storage.to_s.start_with?("#{expected}/")
    end

    def check_mail!(env)
      address = env.fetch("SMTP_ADDRESS", "127.0.0.1")
      refuse!("SMTP host #{address}") unless local_host?(address)
      refuse!("SMTP authentication enabled") unless env.fetch("SMTP_AUTHENTICATION", "none") == "none"
    end

    def check_hosts!(env)
      %w[APP_HOST APP_HOSTS FRONTEND_ORIGIN FRONTEND_URL VITE_API_BASE_URL].each do |key|
        next unless env[key]

        env[key].split(",").each do |value|
          host = URI.parse(value).host || value.split(":").first
          refuse!("#{key}=#{value}") if host && (PRODUCTION_HOST_PATTERNS.any? { |pattern| host.match?(pattern) } || !local_host?(host))
        rescue URI::InvalidURIError
          refuse!("invalid #{key}")
        end
      end
    end

    def local_host?(host)
      %w[localhost 127.0.0.1 ::1].include?(host)
    end

    def refuse!(detail)
      raise SafetyError, "Refusing to start: production configuration detected (#{detail})."
    end

    class Service
      attr_reader :name

      def initialize(name, definition, config)
        @name = name.to_s
        @definition = definition
        @config = config
      end

      def cwd
        Pathname(@definition.fetch("cwd", @config.root.to_s)).expand_path
      end

      def command
        value = @definition.fetch("command")
        raise ConfigError, "services.#{name}.command must be an argv array" unless value.is_a?(Array) && value.all?(String) && value.any?

        value
      end

      def env
        @definition.fetch("env", {}).transform_values(&:to_s)
      end

      def healthcheck
        @definition["healthcheck"]
      end

      def port
        value = @definition["port"]
        value && Integer(value)
      end

      def ports
        @definition.fetch("ports", [port]).compact.map { |value| Integer(value) }
      end

      def log_path
        @config.runtime_root.join("logs", "#{name}.log")
      end

      def pid_path
        @config.runtime_root.join("pids", "#{name}.json")
      end
    end
  end
end
