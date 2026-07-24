# frozen_string_literal: true

require "securerandom"

module Ask
  module CodingProviders
    module ACP
      # Adapter that connects to any ACP-speaking coding agent over stdio.
      #
      # ACP (Agent Client Protocol) is a JSON-RPC 2.0 standard for agent-editor
      # communication. This adapter wraps the ACP client into the generic
      # {Ask::CodingProviders::Adapter} interface. It is the **primary
      # recommended adapter** for new deployments.
      #
      # Works with any ACP-compatible agent:
      # - **Codex** — `ACP_COMMAND='codex acp'` (native ACP support)
      # - **Claude Code** — `ACP_COMMAND='claude acp'` (native ACP support)
      # - **OpenCode** — `ACP_COMMAND='opencode acp'` (native ACP support)
      # - **ZCode** — via ACP bridges like william0wang/zcode-acp or
      #   alexeygrigorev/zcode-acp
      # - **Gemini CLI** — `ACP_COMMAND='gemini-cli acp'` (native ACP support)
      #
      # @example
      #   adapter = Ask::CodingProviders::ACP::Adapter.new(
      #     command: ["codex", "acp"],
      #     cwd: Dir.pwd
      #   )
      #   adapter.start
      #   sid = adapter.create_session("/tmp")
      #   adapter.send_and_stream(sid, "Hello") { |ev| puts ev }
      class Adapter < Ask::CodingProviders::Adapter
        # @param command [Array<String>] the command to spawn the ACP agent
        # @param cwd [String] working directory
        # @param request_timeout [Float] timeout for ACP requests
        def initialize(command:, cwd: ".", request_timeout: 60.0)
          require "ask/acp"

          @command = command
          @cwd = cwd
          @request_timeout = request_timeout
          @client = nil
          @sessions = {}
        end

        def start
          return if @client
          @client = Ask::ACP::Client.new(command: @command, request_timeout: @request_timeout)
          @client.start
          @client.initialize!(client_name: "askoda", client_version: "0.1.0")
        end

        def stop
          @client&.stop
          @client = nil
          @sessions = {}
        end

        def running?
          @client&.running? || false
        end

        def create_session(workspace_path, mode: nil)
          ensure_running
          params = { cwd: workspace_path || @cwd }
          session = @client.session_new(**params)
          sid = session[:id]
          @sessions[sid] = { workspace: workspace_path, mode: mode, created_at: Time.now }
          sid
        end

        def resume_session(session_id)
          ensure_running
          @client.session_resume(session_id)
        rescue => e
          {}
        end

        def subscribe(session_id, after_seq: 0)
          ensure_running
          { "eventSeq" => 0 }
        end

        def send_message(session_id, content)
          ensure_running
          @client.session_prompt(session_id, content)
        end

        def send_and_stream(session_id, content, turn_timeout: 600.0, &block)
          return enum_for(:send_and_stream, session_id, content, turn_timeout: turn_timeout) unless block
          ensure_running

          accumulated = ""
          block.call({ type: "turn.started", seq: 1, payload: { "sessionId" => session_id } })

          result = @client.session_prompt(session_id, content, timeout: turn_timeout) do |event|
            case event[:method]
            when "text"
              delta = event.dig(:params, "content") || ""
              accumulated += delta
              block.call({
                type: "model.streaming", seq: 2,
                payload: { "delta" => delta, "sessionId" => session_id }
              }) unless delta.empty?
            when "turn_complete"
              block.call({
                type: "turn.completed", seq: 3,
                payload: { "response" => accumulated, "sessionId" => session_id }
              })
            when "turn_failed"
              err = event.dig(:params, "error") || "Unknown error"
              block.call({
                type: "turn.failed", seq: 3,
                payload: { "error" => { "message" => err }, "sessionId" => session_id }
              })
            end
          end

          # If the prompt response contains the result and we haven't sent completed yet
          if result.is_a?(Hash)
            stop_reason = result["stopReason"] || result[:stopReason]
            if stop_reason == "cancelled" || stop_reason == "refusal"
              block.call({
                type: "turn.failed", seq: 3,
                payload: { "error" => { "message" => "Turn #{stop_reason}" }, "sessionId" => session_id }
              })
            end
          end
        rescue => e
          block.call({
            type: "turn.failed", seq: 3,
            payload: { "error" => { "message" => e.message }, "sessionId" => session_id }
          })
        end

        def get_events(session_id, after_seq:, limit: nil)
          ensure_running
          {}
        end

        def respond(request_id, result)
          # ACP uses notification-based reverse requests, no direct respond
        end

        def get_workspace_state(workspace_path)
          ensure_running
          {}
        rescue => e
          {}
        end

        # Build an ACP adapter from config.
        # Reads ACP_COMMAND env var (space-separated command + args).
        def self.from_config(workspace_path: Dir.pwd, cli_path: nil, request_timeout: 600, **)
          cmd = cli_path || ENV["ACP_COMMAND"] || raise(
            Ask::CodingProviders::ConfigurationError,
            "Missing ACP_COMMAND. Set ACP_COMMAND or pass cli_path, e.g. ACP_COMMAND='codex acp'"
          )
          new(
            command: cmd.is_a?(String) ? cmd.split : cmd,
            cwd: workspace_path,
            request_timeout: request_timeout
          )
        end

        private

        def ensure_running
          raise Error, "ACP adapter is not running. Call #start first." unless @client&.running?
        end
      end
    end
  end
end

Ask::CodingProviders.register_adapter(:acp, Ask::CodingProviders::ACP::Adapter)
