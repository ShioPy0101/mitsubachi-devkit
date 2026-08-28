# frozen_string_literal: true

require "json"
require "pathname"
require "tempfile"
require "time"

require "lx"
require "lx/system"

module Lx
  class StateStore
    def read(path)
      pathname = Pathname(path)
      return nil unless pathname.file?

      JSON.parse(pathname.read)
    rescue JSON::ParserError
      delete(path)
      nil
    end

    def write(path, value)
      pathname = Pathname(path)
      pathname.dirname.mkpath
      Tempfile.create([pathname.basename.to_s, ".tmp"], pathname.dirname) do |file|
        file.write(JSON.pretty_generate(value))
        file.flush
        file.fsync
        File.rename(file.path, pathname)
      end
    end

    def delete(path)
      Pathname(path).delete if Pathname(path).exist?
    end
  end

  class ProcessManager
    Status = Data.define(:name, :state, :pid, :detail)

    def initialize(config:, backend: ProcessBackend.new, port_probe: PortProbe.new,
                   health_probe: HealthProbe.new, store: StateStore.new)
      @config = config
      @backend = backend
      @port_probe = port_probe
      @health_probe = health_probe
      @store = store
    end

    def start(name)
      service = @config.service(name)
      current = status(name)
      return current if %i[running unhealthy].include?(current.state)

      check_port!(service)
      pid = @backend.spawn(
        command: service.command,
        env: @config.local_environment.merge(service.env),
        cwd: service.cwd,
        log_path: service.log_path
      )
      identity = wait_for_identity(pid)
      unless identity
        @backend.signal(pid, "TERM")
        raise CommandError, "#{name} exited before its process identity could be recorded"
      end

      @store.write(service.pid_path, state_record(service, pid, identity))
      wait_until_healthy(service, pid)
      Status.new(service.name, :running, pid, "started")
    end

    def start_all
      @config.managed_service_names.map { |name| start(name) }
    end

    def stop(name)
      service = @config.service(name)
      record = @store.read(service.pid_path)
      return Status.new(service.name, :stopped, nil, "not running") unless record

      pid = Integer(record["pid"], exception: false)
      unless owned_process?(pid, record)
        @store.delete(service.pid_path)
        return Status.new(service.name, :stale, nil, "removed stale PID")
      end

      @backend.signal(pid, "TERM")
      deadline = @backend.monotonic + @config.stop_timeout
      while @backend.alive?(pid) && @backend.monotonic < deadline
        @backend.sleep(0.1)
      end
      if @backend.alive?(pid)
        @backend.signal(pid, "KILL")
        @backend.sleep(0.1)
      end
      raise CommandError, "#{name} did not stop" if @backend.alive?(pid)

      @store.delete(service.pid_path)
      Status.new(service.name, :stopped, nil, "stopped")
    end

    def stop_all
      @config.managed_service_names.reverse.map { |name| stop(name) }
    end

    def restart_all
      stop_all
      start_all
    end

    def status(name)
      service = @config.service(name)
      record = @store.read(service.pid_path)
      return Status.new(service.name, :stopped, nil, "not running") unless record

      pid = Integer(record["pid"], exception: false)
      unless owned_process?(pid, record)
        @store.delete(service.pid_path)
        return Status.new(service.name, :stale, nil, "removed stale PID")
      end

      if service.healthcheck && !@health_probe.healthy?(service.healthcheck)
        return Status.new(service.name, :unhealthy, pid, "healthcheck failed")
      end

      Status.new(service.name, :running, pid, "healthy")
    end

    def statuses
      @config.managed_service_names.map { |name| status(name) }
    end

    private

    def owned_process?(pid, record)
      pid&.positive? && @backend.alive?(pid) && @backend.identity(pid) == record["identity"]
    end

    def wait_for_identity(pid)
      20.times do
        return nil unless @backend.alive?(pid)

        identity = @backend.identity(pid)
        return identity unless identity.to_s.empty?

        @backend.sleep(0.05)
      end
      nil
    end

    def check_port!(service)
      return unless service.port && @port_probe.open?("127.0.0.1", service.port)

      raise CommandError, "Port #{service.port} is already in use; refusing to start #{service.name}"
    end

    def wait_until_healthy(service, pid)
      return unless service.healthcheck

      deadline = @backend.monotonic + @config.health_timeout
      loop do
        raise CommandError, "#{service.name} exited during startup; see #{service.log_path}" unless @backend.alive?(pid)
        return if @health_probe.healthy?(service.healthcheck)
        break if @backend.monotonic >= deadline

        @backend.sleep(0.2)
      end

      stop(service.name)
      raise CommandError, "#{service.name} healthcheck timed out: #{service.healthcheck}"
    end

    def state_record(service, pid, identity)
      {
        "name" => service.name,
        "pid" => pid,
        "identity" => identity,
        "command" => service.command,
        "cwd" => service.cwd.to_s,
        "stdout" => service.log_path.to_s,
        "stderr" => service.log_path.to_s,
        "healthcheck" => service.healthcheck,
        "started_at" => Time.now.utc.iso8601
      }
    end
  end
end
