# frozen_string_literal: true

require "test_helper"
require "json"
require "fileutils"
require "lx/config"
require "lx/process_manager"

class ProcessManagerTest < Minitest::Test
  class FakeBackend
    attr_reader :spawns, :signals

    def initialize
      @spawns = []
      @signals = []
      @alive = {}
      @identities = {}
      @next_pid = 10_000
      @now = 0.0
    end

    def spawn(**attributes)
      @next_pid += 1
      @spawns << attributes
      @alive[@next_pid] = true
      @identities[@next_pid] = "identity-#{@next_pid}"
      @next_pid
    end

    def alive?(pid)
      @alive.fetch(pid, false)
    end

    def identity(pid)
      @identities[pid]
    end

    def signal(pid, name)
      @signals << [pid, name]
      @alive[pid] = false if %w[TERM KILL].include?(name)
    end

    def monotonic
      @now
    end

    def sleep(seconds)
      @now += seconds
    end

    def make_stale(pid)
      @alive[pid] = false
    end
  end

  class FakePortProbe
    attr_accessor :open

    def initialize(open: false)
      @open = open
    end

    def open?(_host, _port)
      open
    end
  end

  class FakeHealthProbe
    def healthy?(_url)
      true
    end
  end

  def setup
    @tmp = Pathname(Dir.mktmpdir)
    @root = @tmp.join("mitsubachi-devkit")
    @root.join("config").mkpath
    FileUtils.cp(File.expand_path("../config/devkit.yml", __dir__), @root.join("config/devkit.yml"))
    @config = Lx::Config.new(root: @root, env: {})
    @backend = FakeBackend.new
    @port_probe = FakePortProbe.new
    @manager = build_manager
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_startは起動済みサービスを多重起動しない
    first = @manager.start("ruby")
    second = @manager.start("ruby")

    assert_equal :running, first.state
    assert_equal :running, second.state
    assert_equal 1, @backend.spawns.length
  end

  def test_stale_pidを除去して起動する
    first = @manager.start("ruby")
    @backend.make_stale(first.pid)

    restarted = @manager.start("ruby")

    assert_equal :running, restarted.state
    refute_equal first.pid, restarted.pid
    assert_equal 2, @backend.spawns.length
  end

  def test_stopは記録したプロセスだけへSIGTERMを送る
    started = @manager.start("front")

    result = @manager.stop("front")

    assert_equal :stopped, result.state
    assert_equal [[started.pid, "TERM"]], @backend.signals
    refute @config.service("front").pid_path.exist?
  end

  def test_PIDが別プロセスへ再利用された場合は停止しない
    started = @manager.start("nginx")
    @backend.instance_variable_get(:@identities)[started.pid] = "different-process"

    result = @manager.stop("nginx")

    assert_equal :stale, result.state
    assert_empty @backend.signals
  end

  def test_restartは全サービスを停止して再起動する
    @config.managed_service_names.each { |name| @manager.start(name) }
    original_count = @backend.spawns.length

    results = @manager.restart_all

    assert_equal original_count * 2, @backend.spawns.length
    assert results.all? { |status| status.state == :running }
  end

  def test_statusは停止中を返す
    result = @manager.status("mailpit")

    assert_equal :stopped, result.state
    assert_nil result.pid
  end

  def test_管理外プロセスがportを使用中なら起動を拒否する
    @port_probe.open = true

    error = assert_raises(Lx::CommandError) { @manager.start("ruby") }

    assert_match(/Port 3001 is already in use/, error.message)
    assert_empty @backend.spawns
  end

  def test_MailpitのSMTP_port競合も拒否する
    @port_probe.open = true

    error = assert_raises(Lx::CommandError) { @manager.start("mailpit") }

    assert_match(/Port 1025 is already in use/, error.message)
  end

  private

  def build_manager
    Lx::ProcessManager.new(
      config: @config,
      backend: @backend,
      port_probe: @port_probe,
      health_probe: FakeHealthProbe.new
    )
  end
end
