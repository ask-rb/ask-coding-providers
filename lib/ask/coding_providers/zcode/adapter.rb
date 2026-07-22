# frozen_string_literal: true

module Ask
  module CodingProviders
    module ZCode
      # Adapter implementation for ZCode coding agent.
      #
      # Uses AppServerClient for streaming bidirectional communication,
      # or falls back to Client for simple prompt-response mode.
      class Adapter < Ask::CodingProviders::Adapter
        def initialize(cwd: ".", cli_path: nil, request_timeout: 60.0)
          @cwd = cwd
          @cli_path = cli_path
          @request_timeout = request_timeout
          @client = nil
          @use_app_server = ENV.fetch("ZCODE_USE_APP_SERVER", "1") != "0"
          @fallback = nil
          @session_db = ZCodeDB.new
        end

        def start
          if @use_app_server
            @client = AppServerClient.new(cwd: @cwd, cli_path: @cli_path, request_timeout: @request_timeout)
            @client.on_notification { |method, params, request_id| handle_notification(method, params, request_id) }
            @client.start
          else
            @fallback = Client.new(working_dir: @cwd, cli_path: @cli_path)
          end
        end

        def stop
          @client&.stop
          @client = nil
        end

        def running?
          @use_app_server ? (@client&.running? || false) : true
        end

        def create_session(workspace_path, mode: nil)
          return "fallback_#{Time.now.to_i}" unless @use_app_server && @client
          @client.create_session(workspace_path, mode: mode)
        end

        def resume_session(session_id)
          return {} unless @use_app_server && @client
          @client.resume_session(session_id)
        end

        def list_sessions(workspace_path: nil, limit: 20)
          return [] unless @use_app_server && @client
          @client.list_sessions(workspace_path: workspace_path, limit: limit)
        end

        def subscribe(session_id, after_seq: 0)
          return {} unless @use_app_server && @client
          @client.subscribe(session_id, after_seq: after_seq)
        end

        def send_message(session_id, content)
          if @use_app_server && @client
            @client.send_message(session_id, content)
          else
            @fallback&.run(content, session_id: session_id)
          end
        end

        def send_and_stream(session_id, content, turn_timeout: 600.0, &block)
          return enum_for(:send_and_stream, session_id, content, turn_timeout: turn_timeout) unless block
          raise "send_and_stream requires app-server mode" unless @use_app_server && @client

          ev_queue = Queue.new
          my_turn_id = nil
          done = false

          handler = ->(method, params, request_id) do
            if method == "session/event"
              sid = params["sessionId"] || params[:sessionId]
              return unless sid == session_id
              ev = {
                type: params["type"] || params[:type],
                seq: params["seq"] || params[:seq] || 0,
                payload: params["payload"] || params[:payload] || {},
                turn_id: params["turnId"] || params[:turnId]
              }
              my_turn_id ||= ev[:turn_id] if ev[:type] == "turn.started"
              if my_turn_id.nil? || ev[:turn_id] == my_turn_id
                ev_queue << ev
                done = true if %w[turn.completed turn.failed].include?(ev[:type])
              end
            elsif method == "interaction/requestPermission"
              ev_queue << {
                type: "permission.requested", seq: 0,
                payload: {
                  request_id: params["requestId"] || params[:requestId],
                  tool_name: params["toolName"] || params[:toolName] || "",
                  input: params["input"] || params[:input] || {},
                  risk_level: params["riskLevel"] || params[:riskLevel] || "",
                  reason: params["reason"] || params[:reason] || "",
                  tool_call_id: params["toolCallId"] || params[:toolCallId] || ""
                }
              }
            end
          end

          @client.on_notification(&handler)
          begin
            @client.send_message(session_id, content)
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
          return {} unless @use_app_server && @client
          @client.get_events(session_id, after_seq: after_seq, limit: limit)
        end

        def get_workspace_state(workspace_path)
          return {} unless @use_app_server && @client
          @client.read_workspace_state(workspace_path)
        end

        def respond(request_id, result)
          @client&.respond(request_id, result)
        end

        # Handle ZCode-specific session errors.
        # Returns :create_new for model-unavailable errors so the Engine
        # can replace the session with a new one in the same workspace.
        def handle_session_error(session_id, error)
          msg = error.message
          if msg.include?("32031") || msg.include?("模型已不可用") || msg.include?("model is no longer available")
            :create_new
          end
        end

        # ── Session/project queries (delegated to SessionDB) ──

        def list_projects
          @session_db.list_projects
        end

        def find_sessions(directory:, limit: 20)
          @session_db.find_sessions(directory: directory, limit: limit)
        end

        def find_recent_session
          @session_db.find_recent_session
        end

        def find_recent_tui_session(workspace_path)
          @session_db.find_recent_tui_session(workspace_path)
        end

        def session_directory(session_id)
          @session_db.session_directory(session_id)
        end

        def session_history(session_id, limit: 100)
          @session_db.session_history(session_id, limit: limit)
        end

        def recent_sessions
          @session_db.recent_sessions
        end

        private

        def handle_notification(method, params, request_id)
          return unless request_id
          return unless method == "interaction/requestUserInput"
          @client&.respond(request_id, { "response" => "" })
        end
      end
    end
  end
end
