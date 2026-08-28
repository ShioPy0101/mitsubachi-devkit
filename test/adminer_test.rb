# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "lx/adminer"
require "lx/config"

class AdminerTest < Minitest::Test
  def setup
    @tmp = Pathname(Dir.mktmpdir)
    @root = @tmp.join("mitsubachi-devkit")
    @root.join("config").mkpath
    FileUtils.cp(File.expand_path("../config/devkit.yml", __dir__), @root.join("config/devkit.yml"))
    @body = "<?php echo 'Adminer fixture';"
    override = {"adminer" => {"version" => "test", "url" => "https://example.test/adminer.php", "sha256" => Digest::SHA256.hexdigest(@body)}}
    @root.join("config/local.yml").write(YAML.dump(override))
    @config = Lx::Config.new(root: @root, env: {})
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_adminerを検証してatomicに配置する
    fetches = 0
    installer = Lx::Adminer.new(config: @config, fetcher: ->(_url) { fetches += 1; @body })

    assert installer.install!
    refute installer.install!

    assert_equal 1, fetches
    assert_equal @body, @config.runtime_root.join("adminer/index.php").read
  end

  def test_checksum不一致を拒否する
    installer = Lx::Adminer.new(config: @config, fetcher: ->(_url) { "tampered" })

    error = assert_raises(Lx::CommandError) { installer.install! }

    assert_match(/checksum mismatch/, error.message)
    refute @config.runtime_root.join("adminer/index.php").exist?
  end
end
