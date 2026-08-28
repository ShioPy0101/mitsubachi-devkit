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

  def test_adminerをloopback上の管理サービスとして構成する
    config = Lx::Config.new(root: @root, env: {})
    service = config.service("adminer")

    assert_equal "5.5.1", config.adminer_version
    assert_equal 8081, service.port
    assert_equal ["php", "-S", "127.0.0.1:8081", "-t", @root.join("runtime/adminer").to_s], service.command
  end

  def test_Railsのメール配送をMailpitへ向ける
    config = Lx::Config.new(root: @root, env: {})
    env = config.service("ruby").env

    assert_equal "127.0.0.1", env.fetch("SMTP_ADDRESS")
    assert_equal "1025", env.fetch("SMTP_PORT")
    assert_equal "none", env.fetch("SMTP_AUTHENTICATION")
    assert_equal "false", env.fetch("SMTP_ENABLE_STARTTLS_AUTO")
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

  def test_YAMLで上書きしたdevelopmentデータベースをRailsへ渡す
    write_override("database" => {"name" => "custom_development", "url" => "postgresql:///custom_development"})
    config = Lx::Config.new(root: @root, env: {})

    assert_equal "postgresql:///custom_development", config.local_environment.fetch("DATABASE_URL")
    assert config.ensure_safe!
  end

  def test_runtime外のストレージを拒否する
    write_override("services" => {"ruby" => {"env" => {"FILE_STORAGE_ROOT" => "/srv/mitsubachi/files"}}})

    assert_raises(Lx::SafetyError) { Lx::Config.new(root: @root, env: {}).ensure_safe! }
  end

  def test_外部SMTPの上書きを拒否する
    config = Lx::Config.new(root: @root, env: {"SMTP_ADDRESS" => "smtp.production.example"})

    assert_raises(Lx::SafetyError) { config.ensure_safe! }
  end

  private

  def write_override(value)
    @root.join("config/local.yml").write(YAML.dump(value))
  end
end
