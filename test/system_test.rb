# frozen_string_literal: true

require "test_helper"
require "lx/system"

class SystemTest < Minitest::Test
  FakeStatus = Data.define(:success?)

  def test_spawnは標準入力をdev_nullへ接続する
    backend = Lx::ProcessBackend.new
    options = nil

    Dir.mktmpdir do |directory|
      replace_singleton_method(Process, :spawn) { |*arguments| options = arguments.last; 12_345 }
      replace_singleton_method(Process, :detach) { |_pid| nil }
      backend.spawn(
        command: ["example"],
        env: {},
        cwd: Pathname(directory),
        log_path: Pathname(directory).join("service.log")
      )
    end

    assert_equal File::NULL, options[:in]
  end

  def test_identityは変更され得るcommandを含めない
    arguments = nil
    capture = lambda do |*values|
      arguments = values
      ["Fri Aug 28 22:32:18 2026\n", FakeStatus.new(true)]
    end

    replace_singleton_method(Open3, :capture2, &capture)
    identity = Lx::ProcessBackend.new.identity(12_345)

    assert_equal "Fri Aug 28 22:32:18 2026", identity
    assert_equal [{"LC_ALL" => "C"}, "ps", "-p", "12345", "-o", "lstart="], arguments
  end

  private

  def replace_singleton_method(object, name, &replacement)
    @original_methods ||= []
    @original_methods << [object, name, object.method(name)]
    object.define_singleton_method(name, &replacement)
  end

  def teardown
    @original_methods&.reverse_each do |object, name, original|
      object.define_singleton_method(name, original)
    end
  end
end
