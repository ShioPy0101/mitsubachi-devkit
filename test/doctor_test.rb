# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "lx/config"
require "lx/doctor"

class DoctorTest < Minitest::Test
  FakeStatus = Struct.new(:success?, :exitstatus)

  class FakeRunner
    def initialize(missing: [])
      @missing = missing
    end

    def available?(command, cwd: nil)
      !@missing.include?(command)
    end

    def capture(*command)
      Lx::Result.new("#{command.first} 1.0\n", "", FakeStatus.new(true, 0))
    end
  end

  class FakeDatabase
    def server_reachable? = true
    def database_exists? = true
  end

  def setup
    @tmp = Pathname(Dir.mktmpdir)
    @root = @tmp.join("mitsubachi-devkit")
    @root.join("config").mkpath
    FileUtils.cp(File.expand_path("../config/devkit.yml", __dir__), @root.join("config/devkit.yml"))
    {"ruby" => "Gemfile", "front" => "package.json", "infra" => "README.md"}.each do |name, marker|
      path = @tmp.join("mitsubachi-#{name}")
      path.mkpath
      path.join(marker).write("fixture")
    end
    @config = Lx::Config.new(root: @root, env: {})
    @config.runtime_root.join("storage").mkpath
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_すべて揃っていれば診断に成功する
    checks = Lx::Doctor.new(config: @config, runner: FakeRunner.new, database: FakeDatabase.new).checks

    assert checks.all?(&:ok)
    assert checks.any? { |check| check.label == "ffmpeg" && check.detail.include?("1.0") }
  end

  def test_不足コマンドを報告するだけでインストールしない
    checks = Lx::Doctor.new(config: @config, runner: FakeRunner.new(missing: ["ffmpeg"]), database: FakeDatabase.new).checks
    ffmpeg = checks.find { |check| check.label == "ffmpeg" }

    refute ffmpeg.ok
    assert_equal "not found", ffmpeg.detail
    assert_match(/Install ffmpeg manually/, ffmpeg.help)
  end
end
