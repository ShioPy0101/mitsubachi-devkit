# frozen_string_literal: true

require "test_helper"
require "open3"

class CLITest < Minitest::Test
  def test_helpを表示できる
    root = File.expand_path("..", __dir__)
    stdout, stderr, status = Open3.capture3(File.join(root, "lx"), "help", chdir: root)

    assert status.success?, stderr
    assert_includes stdout, "Usage: lx <command>"
    assert_includes stdout, "pm <command>"
  end

  def test_不明なコマンドは終了コード2を返す
    root = File.expand_path("..", __dir__)
    _stdout, stderr, status = Open3.capture3(File.join(root, "lx"), "unknown", chdir: root)

    assert_equal 2, status.exitstatus
    assert_includes stderr, "Unknown command"
  end
end
