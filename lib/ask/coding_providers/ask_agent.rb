# frozen_string_literal: true

require_relative "ask_agent/adapter"

module Ask
  module CodingProviders
    # AskAgent coding provider — uses Ask::Agent::Session in-process.
    #
    # No app-server, no external binary. Sessions run in the same process.
    #
    # @example
    #   adapter = Ask::CodingProviders::AskAgent::Adapter.new(
    #     model: "deepseek-v4-flash",
    #     provider: "opencode_go"
    #   )
    module AskAgent
    end
  end
end
