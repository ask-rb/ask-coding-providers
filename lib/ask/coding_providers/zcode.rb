# frozen_string_literal: true

require_relative "zcode/app_server_client"
require_relative "zcode/client"
require_relative "zcode/adapter"
require_relative "zcode/session_db"

module Ask
  module CodingProviders
    # ZCode coding agent provider for the ask-coder ecosystem.
    #
    # Provides a JSON-RPC/stdio client for ZCode's app-server,
    # a --prompt fallback mode, and an Adapter implementation
    # that plugs into Ask::Coder.
    module ZCode
      class Error < Ask::CodingProviders::Error; end
      class AppServerUnavailable < Error; end
      class SessionUnavailable < Error; end
      class PromptAlreadyRunning < Error; end
      class TimeoutError < Ask::CodingProviders::TimeoutError; end
      class CLIError < Error; end
    end
  end
end
