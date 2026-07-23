# frozen_string_literal: true

require_relative "codex/app_server_client"
require_relative "codex/adapter"

module Ask
  module CodingProviders
    module Codex
      class Error < Ask::CodingProviders::Error; end
      class TimeoutError < Ask::CodingProviders::TimeoutError; end
    end
  end
end
