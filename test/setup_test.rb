# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "stringio"
require "lx/config"
require "lx/setup"

class SetupTest < Minitest::Test
  FakeStatus = Struct.new(:success?, :exitstatus)

  class FakeRunner
    attr_reader :runs

    def initialize
      @runs = []
    end

    def available?(_command, cwd: nil) = true

    def capture(*command, **)
      @runs << [:capture, command]
      Lx::Result.new("", "", FakeStatus.new(true, 0))
    end

    def run!(*command, **)
      @runs << [:run, command]
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

  def setup
    @tmp = Pathname(Dir.mktmpdir)
    @root = @tmp.join("mitsubachi-devkit")
    @root.join("config/nginx").mkpath
    %w[config/devkit.yml config/nginx/nginx.conf.erb config/local.yml.example .env.local.example].each do |relative|
      source = File.expand_path("../#{relative}", __dir__)
      destination = @root.join(relative)
      destination.dirname.mkpath
      FileUtils.cp(source, destination)
    end
    @tmp.join("mitsubachi-ruby").tap { |path| path.mkpath; path.join("Gemfile").write("") }
    @tmp.join("mitsubachi-front").tap { |path| path.mkpath; path.join("package.json").write("{}"); path.join("node_modules").mkpath }
    @config = Lx::Config.new(root: @root, env: {})
    @runner = FakeRunner.new
    @database = FakeDatabase.new
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_setupは既存設定を壊さず冪等に初期化する
    setup = Lx::Setup.new(config: @config, runner: @runner, database: @database, output: StringIO.new)

    2.times { setup.run }

    assert @root.join("runtime/storage/drive_items").directory?
    assert @root.join(".env.local").file?
    assert @root.join("config/local.yml").file?
    assert_equal 2, @database.prepares
    refute @runner.runs.any? { |kind, command| kind == :run && command == ["npm", "install"] }
  end
end
