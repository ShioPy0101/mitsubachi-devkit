# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "lx/config"
require "lx/runtime"

class RuntimeTest < Minitest::Test
  def setup
    @tmp = Pathname(Dir.mktmpdir)
    @root = @tmp.join("mitsubachi-devkit")
    @root.join("config/nginx").mkpath
    FileUtils.cp(File.expand_path("../config/devkit.yml", __dir__), @root.join("config/devkit.yml"))
    FileUtils.cp(File.expand_path("../config/nginx/nginx.conf.erb", __dir__), @root.join("config/nginx/nginx.conf.erb"))
    FileUtils.cp(File.expand_path("../.env.local.example", __dir__), @root.join(".env.local.example"))
    FileUtils.cp(File.expand_path("../config/local.yml.example", __dir__), @root.join("config/local.yml.example"))
    @config = Lx::Config.new(root: @root, env: {})
    @runtime = Lx::Runtime.new(@config)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_必要なruntimeディレクトリを冪等に作成する
    2.times { @runtime.prepare_directories! }

    %w[logs pids storage/drive_items tmp nginx adminer].each do |relative|
      assert @config.runtime_root.join(relative).directory?
    end
  end

  def test_既存のローカル設定を上書きしない
    @root.join(".env.local").write("CUSTOM=value\n")

    2.times { @runtime.generate_local_files! }

    assert_equal "CUSTOM=value\n", @root.join(".env.local").read
    assert @root.join("config/local.yml").file?
  end

  def test_nginx設定へローカルstorageとportを反映する
    @runtime.prepare_directories!

    path = @runtime.render_nginx!

    assert_includes path.read, "listen 127.0.0.1:8080"
    assert_includes path.read, "alias #{@config.runtime_root}/storage/drive_items/"
    assert_includes path.read, "add_header Accept-Ranges bytes always"
  end
end
