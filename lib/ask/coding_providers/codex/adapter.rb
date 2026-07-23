# frozen_string_literal: true

module Ask
  module CodingProviders
    module Codex
      # Adapter implementation for the Codex app-server.
      #
      # Communicates with `codex app-server` over stdio JSON-RPC 2.0.
      # Supports thread (session) lifecycle and streaming turns.
      class Adapter < Ask::CodingProviders::Adapter
        def initialize(cwd: ".", cli_path: nil, request_timeout: 60.0)
          @cwd = cwd
          @cli_path = cli_path
          @request_timeout = request_timeout
          @client = nil
        end

        def start
          return if @client
          @client = AppServerClient.new(cwd: @cwd, cli_path: @cli_path, request_timeout: @request_timeout)
          @client.on_notification { |method, params, request_id| handle_notification(method, params, request_id) }
          @client.start
          # Perform the initialize handshake
          @client.initialize!
          @client.send_initialized
        end

        def stop
          @client&.stop
          @client = nil
        end

        def running?
          @client&.running? || false
        end

        def create_session(workspace_path, mode: nil)
          ensure_running
          thread = @client.thread_start(cwd: workspace_path)
          tid = thread["id"] || thread[:id]
          raise Error, "thread/start did not return thread id" unless tid
          tid
        end

        def resume_session(session_id)
          ensure_running
          @client.thread_resume(session_id)
        rescue => e
          {}
        end

        def subscribe(session_id, after_seq: 0)
          ensure_running
          { "eventSeq" => 0 }
        end

        def send_message(session_id, content)
          ensure_running
          @client.turn_start(session_id, content)
        end

        def send_and_stream(session_id, content, turn_timeout: 600.0, &block)
          return enum_for(:send_and_stream, session_id, content, turn_timeout: turn_timeout) unless block
          raise "send_and_stream requires app-server mode" unless @client

          ev_queue = Queue.new
          my_turn_id = nil
          done = false

          handler = ->(method, params, request_id) do
            case method
            when "turn/started"
              my_turn_id = params["turnId"] || params[:turnId]
              ev_queue << {
                type: "turn.started", seq: params["seq"] || params[:seq] || 0,
                payload: { "sessionId" => session_id }
              }
            when "item/agentMessage/delta"
              tid = params["turnId"] || params[:turnId]
              if my_turn_id.nil? || tid == my_turn_id
                ev_queue << {
                  type: "model.streaming", seq: params["seq"] || params[:seq] || 0,
                  payload: { "delta" => params["content"] || params[:content] || "", "sessionId" => session_id }
                }
              end
            when "turn/completed"
              tid = params["turnId"] || params[:turnId]
              if my_turn_id.nil? || tid == my_turn_id
                response = params.dig("response", "message") || params.dig("turn", "response") || ""
                ev_queue << {
                  type: "turn.completed", seq: params["seq"] || params[:seq] || 0,
                  payload: { "response" => response, "sessionId" => session_id,
                             "tokenCount" => params["tokenCount"] || params[:tokenCount] || 0 }
                }
                done = true
              end
            when "turn/failed"
              error_msg = params.dig("error", "message") || "Turn failed"
              ev_queue << {
                type: "turn.failed", seq: params["seq"] || params[:seq] || 0,
                payload: { "error" => { "message" => error_msg }, "sessionId" => session_id }
              }
              done = true
            end
          end

          @client.on_notification(&handler)
          begin
            @client.turn_start(session_id, content)
            deadline = Time.now + turn_timeout
            until done
              remaining = deadline - Time.now
              break if remaining <= 0
              begin
                block.call(ev_queue.pop(timeout: remaining))
              rescue ThreadError
                break
              end
            end
          end
        end

        def get_events(session_id, after_seq:, limit: nil)
          ensure_running
          {}
        end

        def respond(request_id, result)
          @client&.respond(request_id, result)
        end

        def get_workspace_state(workspace_path)
          ensure_running
          @client.read_workspace_state
        rescue => e
          {}
        end

        # Build a Codex adapter from config.
        def self.from_config(workspace_path: Dir.pwd, cli_path: nil, request_timeout: 600, **)
          new(cwd: workspace_path, cli_path: cli_path, request_timeout: request_timeout)
        end

        private

        def ensure_running
          raise Error, "Codex app-server is not running. Call #start first." unless @client&.running?
        end

        def handle_notification(method, params, request_id)
          # Auto-respond to user input requests
          return unless request_id
          return unless method == "ToolRequestUserInput"
          @client&.respond(request_id, { "response" => "" })
        end
      end
    end
  end
end

Ask::CodingProviders.register_adapter(:codex, Ask::CodingProviders::Codex::Adapter)
