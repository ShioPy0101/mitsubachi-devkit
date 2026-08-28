# frozen_string_literal: true

module Lx
  class Error < StandardError; end
  class ConfigError < Error; end
  class SafetyError < Error; end
  class CommandError < Error; end
end
