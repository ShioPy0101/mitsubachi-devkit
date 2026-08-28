# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "stringio"
require "lx/config"
require "lx/environment"
require "lx/process_manager"

class EnvironmentTest < Minitest::Test
  FakeStatus = Struct.new(:success?, :exitstatus)

  class FakeRunner
    def initialize(missing: [])
      @missing = missing
    end

    def available?(command, cwd: nil)
      !@missing.include?(command)
    end

    def capture(*)
      Lx::Result.new("", "", FakeStatus.new(true, 0))
    end
  end

  class FakeDatabase
    attr_reader :prepares

    def initialize
      @prepares = 0
    end

    def prepare!(output:)
      @prepares += 1
    end
  end

  class FakeProcessManager
    attr_reader :starts, :stops

    def initialize(names, running: false)
      @names = names
      @running = running
      @starts = []
      @stops = []
    end

    def statuses
      @names.map do |name|
        state = @running ? :running : :stopped
        Lx::ProcessManager::Status.new(name, state, @running ? 1234 : nil, @running ? "healthy" : "not running")
      end
    end

    def start(name)
      @starts << name
      Lx::ProcessManager::Status.new(name, :running, 2000 + @starts.length, "started")
    end

    def stop(name)
      @stops << name
    end
  end

  def setup
    @tmp = Pathname(Dir.mktmpdir)
    @root = @tmp.join("mitsubachi-devkit")
    @root.join("config/nginx").mkpath
    FileUtils.cp(File.expand_path("../config/devkit.yml", __dir__), @root.join("config/devkit.yml"))
    FileUtils.cp(File.expand_path("../config/nginx/nginx.conf.erb", __dir__), @root.join("config/nginx/nginx.conf.erb"))
    @tmp.join("mitsubachi-ruby").tap { |path| path.mkpath; path.join("Gemfile").write(""); path.join("bin").mkpath; path.join("bin/rails").write(""); path.join("bin/rails").chmod(0o755) }
    @tmp.join("mitsubachi-front").tap { |path| path.mkpath; path.join("package.json").write("{}") }
    @config = Lx::Config.new(root: @root, env: {})
    @database = FakeDatabase.new
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_設定順に全サービスを起動する
    manager = FakeProcessManager.new(@config.managed_service_names)

    statuses = environment(manager:).start

    assert_equal %w[ruby front nginx mailpit], manager.starts
    assert_equal 1, @database.prepares
    assert statuses.all? { |status| status.state == :running }
  end

  def test_全サービス起動済みでもmigrationだけ安全に再実行する
    manager = FakeProcessManager.new(@config.managed_service_names, running: true)

    environment(manager:).start

    assert_empty manager.starts
    assert_equal 1, @database.prepares
  end

  def test_必要コマンド不足なら何も起動しない
    manager = FakeProcessManager.new(@config.managed_service_names)

    error = assert_raises(Lx::CommandError) { environment(manager:, missing: ["ffmpeg"]).start }

    assert_match(/ffmpeg/, error.message)
    assert_empty manager.starts
    assert_equal 0, @database.prepares
  end

  private

  def environment(manager:, missing: [])
    Lx::Environment.new(
      config: @config,
      runner: FakeRunner.new(missing:),
      process_manager: manager,
      database: @database,
      output: StringIO.new
    )
  end
end
