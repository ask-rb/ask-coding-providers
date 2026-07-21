# frozen_string_literal: true

require_relative "coding_providers/version"
require_relative "coding_providers/adapter"

module Ask
  module CodingProviders
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class ConnectionError < Error; end
    class TimeoutError < Error; end
  end
end

require_relative "coding_providers/zcode"
