# frozen_string_literal: true

require "erb"
require "fileutils"
require "pathname"

module Lx
  class Runtime
    DIRECTORIES = %w[logs pids storage/drive_items tmp nginx].freeze

    def initialize(config)
      @config = config
    end

    def prepare_directories!
      DIRECTORIES.each { |relative| @config.runtime_root.join(relative).mkpath }
    end

    def generate_local_files!
      copy_unless_exists(@config.root.join(".env.local.example"), @config.root.join(".env.local"))
      copy_unless_exists(@config.root.join("config/local.yml.example"), @config.root.join("config/local.yml"))
    end

    def render_nginx!
      template = @config.root.join("config/nginx/nginx.conf.erb")
      destination = @config.runtime_root.join("nginx/nginx.conf")
      raise ConfigError, "Nginx template not found: #{template}" unless template.file?

      content = ERB.new(template.read, trim_mode: "-").result(binding)
      write_if_changed(destination, content)
      destination
    end

    private

    def ruby_port
      @config.service("ruby").port
    end

    def front_port
      @config.service("front").port
    end

    def nginx_port
      @config.service("nginx").port
    end

    def runtime_root
      @config.runtime_root.to_s
    end

    def storage_root
      @config.runtime_root.join("storage").to_s
    end

    def copy_unless_exists(source, destination)
      return false if destination.exist?

      FileUtils.cp(source, destination)
      true
    end

    def write_if_changed(path, content)
      return false if path.file? && path.read == content

      path.dirname.mkpath
      path.write(content)
      true
    end
  end
end
