# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "lx/config"

class ConfigTest < Minitest::Test
  def setup
    @tmp = Pathname(Dir.mktmpdir)
    @root = @tmp.join("mitsubachi-devkit")
    @root.join("config").mkpath
    FileUtils.cp(File.expand_path("../config/devkit.yml", __dir__), @root.join("config/devkit.yml"))
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_兄弟リポジトリを自動検出する
    config = Lx::Config.new(root: @root, env: {})

    assert_equal @tmp.join("mitsubachi-ruby"), config.repository("ruby")
    assert_equal @tmp.join("mitsubachi-front"), config.repository("front")
    assert_equal @tmp.join("mitsubachi-infra"), config.repository("infra")
  end

  def test_env_localでリポジトリパスを上書きする
    custom = @tmp.join("custom-ruby")
    @root.join(".env.local").write("MITSUBACHI_RUBY_ROOT=#{custom}\n")

    assert_equal custom, Lx::Config.new(root: @root, env: {}).repository("ruby")
  end

  def test_コマンドはargv配列として読み込む
    command = Lx::Config.new(root: @root, env: {}).service("ruby").command

    assert_equal ["bin/rails", "server", "-b", "127.0.0.1", "-p", "3001"], command
  end

  def test_production環境を拒否する
    write_override("services" => {"ruby" => {"env" => {"RAILS_ENV" => "production"}}})

    error = assert_raises(Lx::SafetyError) { Lx::Config.new(root: @root, env: {}).ensure_safe! }
    assert_match(/Refusing to start/, error.message)
  end

  def test_shellから渡されたproduction環境を拒否する
    config = Lx::Config.new(root: @root, env: {"RAILS_ENV" => "production"})

    assert_raises(Lx::SafetyError) { config.ensure_safe! }
  end

  def test_productionデータベースを拒否する
    write_override("services" => {"ruby" => {"env" => {"DATABASE_URL" => "postgresql:\/\/db.example\/mitsubachi_production"}}})

    assert_raises(Lx::SafetyError) { Lx::Config.new(root: @root, env: {}).ensure_safe! }
  end

  def test_ローカルsocketのdevelopmentデータベースを許可する
    assert Lx::Config.new(root: @root, env: {}).ensure_safe!
  end

  def test_runtime外のストレージを拒否する
    write_override("services" => {"ruby" => {"env" => {"FILE_STORAGE_ROOT" => "/srv/mitsubachi/files"}}})

    assert_raises(Lx::SafetyError) { Lx::Config.new(root: @root, env: {}).ensure_safe! }
  end

  private

  def write_override(value)
    @root.join("config/local.yml").write(YAML.dump(value))
  end
end
