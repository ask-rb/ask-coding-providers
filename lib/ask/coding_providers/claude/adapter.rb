# frozen_string_literal: true

require "json"
require "open3"

module Ask
  module CodingProviders
    module Claude
      # Adapter for Claude Code CLI.
      #
      # Uses `claude -p --output-format=stream-json` for non-interactive prompts.
      # Streams JSON events via stdout for real-time response display.
      #
      # @example
      #   adapter = Ask::CodingProviders::Claude::Adapter.new(cli_path: "claude")
      #   adapter.start
      #   sid = adapter.create_session("/tmp")
      #   adapter.send_and_stream(sid, "Hello") { |ev| puts ev }
      class Adapter < Ask::CodingProviders::Adapter
        def initialize(cli_path: "claude", cwd: ".", request_timeout: 120.0)
          @cli_path = cli_path
          @cwd = cwd
          @request_timeout = request_timeout
          @started = false
          @sessions = {}
        end

        def start
          @started = true
        end

        def stop
          @started = false
          @sessions = {}
        end

        def running?
          @started
        end

        def create_session(workspace_path, mode: nil)
          ensure_started
          sid = "sess_#{SecureRandom.uuid}"
          @sessions[sid] = { workspace: workspace_path, mode: mode, created_at: Time.now }
          sid
        end

        def resume_session(session_id)
          @sessions&.dig(session_id) || {}
        end

        def subscribe(session_id, after_seq: 0)
          { "eventSeq" => 0 }
        end

        def send_message(session_id, content)
          ensure_started
          run_claude(content)
        end

        def send_and_stream(session_id, content, turn_timeout: 600.0, &block)
          return enum_for(:send_and_stream, session_id, content, turn_timeout: turn_timeout) unless block
          ensure_started

          block.call({ type: "turn.started", seq: 1, payload: { "sessionId" => session_id } })

          deadline = Time.now + (turn_timeout || @request_timeout)
          accumulated = ""

          begin
            stdin, stdout, stderr, wait_thr = Open3.popen3(
              @cli_path, "-p", content.to_s,
              "--verbose", "--output-format=stream-json",
              chdir: @cwd
            )
            stdin.close

            # Read JSON events from stdout
            stdout.each_line do |line|
              break if Time.now > deadline
              line = line.strip
              next if line.empty?

              begin
                event = JSON.parse(line)
              rescue JSON::ParserError
                next
              end

              case event["type"]
              when "assistant"
                msg = event["message"] || {}
                (msg["content"] || []).each do |block|
                  if block["type"] == "text" && block["text"]
                    delta = block["text"]
                    accumulated += delta
                    block.call({
                      type: "model.streaming", seq: 2,
                      payload: { "delta" => delta, "sessionId" => session_id }
                    })
                  end
                end
              when "result"
                is_error = event["is_error"]
                if is_error
                  err = event["result"] || "Claude error"
                  block.call({
                    type: "turn.failed", seq: 3,
                    payload: { "error" => { "message" => err }, "sessionId" => session_id }
                  })
                else
                  block.call({
                    type: "turn.completed", seq: 3,
                    payload: { "response" => accumulated, "sessionId" => session_id }
                  })
                end
              when "error"
                err_msg = event["message"] || event["error"] || "Claude error"
                block.call({
                  type: "turn.failed", seq: 3,
                  payload: { "error" => { "message" => err_msg }, "sessionId" => session_id }
                })
              end
            end

            stdout.close rescue nil
            stderr.close rescue nil
            wait_thr&.join(5)

          rescue => e
            block.call({
              type: "turn.failed", seq: 3,
              payload: { "error" => { "message" => e.message }, "sessionId" => session_id }
            })
          end
        end

        def get_events(session_id, after_seq:, limit: nil)
          {}
        end

        def respond(request_id, result)
        end

        def get_workspace_state(workspace_path)
          {}
        end

        def self.from_config(workspace_path: Dir.pwd, cli_path: nil, request_timeout: 120, **)
          new(cli_path: cli_path || "claude", cwd: workspace_path, request_timeout: request_timeout)
        end

        private

        def ensure_started
          raise Error, "Claude adapter not started" unless @started
        end

        def run_claude(content)
          stdout, stderr, wait_thr = Open3.capture3(
            @cli_path, "-p", content.to_s,
            "--verbose", "--output-format=stream-json",
            chdir: @cwd
          )
          events = stdout.split("\n").filter_map { |l| JSON.parse(l) rescue nil }
          result = events.find { |e| e["type"] == "result" }
          if result && result["is_error"]
            { "error" => result["result"] || "Claude error" }
          else
            text = events
              .select { |e| e["type"] == "assistant" }
              .flat_map { |e| (e.dig("message", "content") || []).map { |c| c["text"] } }
              .join
            { "response" => text }
          end
        end
      end
    end
  end
end

Ask::CodingProviders.register_adapter(:claude, Ask::CodingProviders::Claude::Adapter)
