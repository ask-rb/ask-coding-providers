# frozen_string_literal: true

require_relative "coding_providers/version"
require_relative "coding_providers/adapter"

module Ask
  module CodingProviders
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class ConnectionError < Error; end
    class TimeoutError < Error; end

    # Registry of coding provider adapters by name.
    # Adapters register themselves via {register_adapter}.
    # The CLI resolves the active adapter via {build_adapter}.
    #
    # @example
    #   adapter = Ask::CodingProviders.build_adapter("zcode", workspace_path: Dir.pwd)
    #   adapter = Ask::CodingProviders.build_adapter("ask_agent", model: "deepseek-v4-flash")
    @adapter_registry = {}

    class << self
      # Register a coding adapter class under a name.
      # Called automatically by adapter files when loaded.
      def register_adapter(name, klass)
        @adapter_registry[name.to_s] = klass
      end

      # Resolve an adapter class by name.
      # @raise [ConfigurationError] if unknown
      def resolve_adapter(name)
        @adapter_registry[name.to_s] || raise(
          ConfigurationError,
          "Unknown coding provider: #{name.inspect}. " \
          "Available: #{@adapter_registry.keys.join(', ')}. " \
          "Set CODING_PROVIDER in your environment."
        )
      end

      # Build an adapter instance by name, passing config options.
      # Each adapter's .from_config class method decides how to use the config.
      def build_adapter(name, **config)
        resolve_adapter(name).from_config(**config)
      end
    end
  end
end

require_relative "coding_providers/zcode"
require_relative "coding_providers/ask_agent"
require_relative "coding_providers/codex"
require_relative "coding_providers/acp"
