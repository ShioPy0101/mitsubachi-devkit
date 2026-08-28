# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "net/http"
require "socket"
require "timeout"
require "yaml"
require "lx/config"
require "lx/runtime"

class NginxRangeTest < Minitest::Test
  def setup
    skip "nginx is not installed" unless system("nginx", "-v", out: File::NULL, err: File::NULL)

    @tmp = Pathname(Dir.mktmpdir)
    @root = @tmp.join("mitsubachi-devkit")
    @root.join("config/nginx").mkpath
    FileUtils.cp(File.expand_path("../config/devkit.yml", __dir__), @root.join("config/devkit.yml"))
    FileUtils.cp(File.expand_path("../config/nginx/nginx.conf.erb", __dir__), @root.join("config/nginx/nginx.conf.erb"))
    @upstream = TCPServer.new("127.0.0.1", 0)
    @nginx_port = unused_port
    write_overrides
    @config = Lx::Config.new(root: @root, env: {})
    Lx::Runtime.new(@config).prepare_directories!
    Lx::Runtime.new(@config).render_nginx!
    @config.runtime_root.join("storage/drive_items/range.txt").write("0123456789")
    start_upstream
    start_nginx
  end

  def teardown
    Process.kill("TERM", -@nginx_pid) if @nginx_pid
  rescue Errno::ESRCH
    nil
  ensure
    @upstream&.close
    @upstream_thread&.kill
    FileUtils.remove_entry(@tmp) if @tmp&.exist?
  end

  def test_X_Accel_Redirect経由のRange_requestを206で配信する
    request = Net::HTTP::Get.new("/api/download")
    request["Range"] = "bytes=2-5"

    response = Net::HTTP.start("127.0.0.1", @nginx_port) { |http| http.request(request) }

    assert_equal "206", response.code
    assert_equal "2345", response.body
    assert_equal "bytes 2-5/10", response["Content-Range"]
    assert_equal "bytes", response["Accept-Ranges"]
  end

  def test_internal_storageへ直接アクセスできない
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@nginx_port}/internal/storage/drive_items/range.txt"))

    assert_equal "404", response.code
  end

  private

  def write_overrides
    override = {
      "services" => {
        "ruby" => {"port" => @upstream.addr[1]},
        "front" => {"port" => unused_port},
        "nginx" => {"port" => @nginx_port}
      }
    }
    @root.join("config/local.yml").write(YAML.dump(override))
  end

  def unused_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def start_upstream
    @upstream_thread = Thread.new do
      loop do
        socket = @upstream.accept
        socket.readpartial(4096)
        socket.write(<<~HTTP.gsub("\n", "\r\n"))
          HTTP/1.1 200 OK
          X-Accel-Redirect: /internal/storage/drive_items/range.txt
          Content-Type: text/plain
          Content-Length: 0
          Connection: close

        HTTP
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def start_nginx
    log = @tmp.join("nginx-process.log")
    @nginx_pid = Process.spawn(
      "nginx", "-p", "#{@config.runtime_root}/nginx/", "-c", @config.runtime_root.join("nginx/nginx.conf").to_s,
      "-g", "daemon off;", out: log.to_s, err: log.to_s, pgroup: true
    )
    Timeout.timeout(5) do
      sleep(0.05) until port_open?
    end
  rescue Timeout::Error
    flunk("nginx did not start:\n#{log.read}")
  end

  def port_open?
    Socket.tcp("127.0.0.1", @nginx_port, connect_timeout: 0.1) { true }
  rescue SystemCallError
    false
  end
end
