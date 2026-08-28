# frozen_string_literal: true

require "fileutils"
require "net/http"
require "open3"
require "pathname"
require "socket"
require "uri"

require "lx"

module Lx
  Result = Data.define(:stdout, :stderr, :status) do
    def success?
      status.success?
    end
  end

  class CommandRunner
    def available?(command, cwd: nil)
      if command.include?(File::SEPARATOR)
        path = Pathname(command)
        path = Pathname(cwd).join(path) unless path.absolute?
        return path.file? && path.executable?
      end

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        path = Pathname(directory).join(command)
        path.file? && path.executable?
      end
    end

    def capture(*command, env: {}, chdir: nil)
      options = {}
      options[:chdir] = chdir.to_s if chdir
      stdout, stderr, status = Open3.capture3(env, *command, **options)
      Result.new(stdout, stderr, status)
    end

    def run!(*command, env: {}, chdir: nil, output: $stdout)
      result = capture(*command, env:, chdir:)
      output.print(result.stdout)
      output.print(result.stderr)
      return result if result.success?

      raise CommandError, "Command failed (#{result.status.exitstatus}): #{command.join(' ')}"
    end
  end

  class ProcessBackend
    def spawn(command:, env:, cwd:, log_path:)
      FileUtils.mkdir_p(log_path.dirname)
      log = File.open(log_path, "a")
      log.sync = true
      log.puts("\n==> #{Time.now}: #{command.join(' ')}")
      pid = Process.spawn(env, *command, chdir: cwd.to_s, in: File::NULL, out: log, err: log, pgroup: true)
      Process.detach(pid)
      pid
    ensure
      log&.close
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def identity(pid)
      output, status = Open3.capture2({"LC_ALL" => "C"}, "ps", "-p", pid.to_s, "-o", "lstart=")
      return nil unless status.success?

      output.strip
    end

    def signal(pid, name)
      Process.kill(name, -pid)
    rescue Errno::ESRCH
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def sleep(seconds)
      Kernel.sleep(seconds)
    end
  end

  class PortProbe
    def open?(host, port)
      Socket.tcp(host, port, connect_timeout: 0.2) { true }
    rescue SystemCallError, IOError
      false
    end
  end

  class HealthProbe
    def healthy?(url)
      uri = URI.parse(url)
      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 0.5,
        read_timeout: 1
      ) { |http| http.get(uri.request_uri) }
      response.code.to_i.between?(200, 399)
    rescue URI::InvalidURIError, SystemCallError, IOError, Timeout::Error
      false
    end
  end
end
