# frozen_string_literal: true

require "json"
require "open3"

module Ask
  module CodingProviders
    module ZCode
      # ZCode app-server JSON-RPC client.
      #
      # Spawns `zcode app-server` as a subprocess and communicates over stdio
      # using NDJSON (one JSON object per line, no Content-Length headers).
      #
      # Thread-safe: all state is guarded by a Mutex.
      class AppServerClient
        CLI_PATHS = [
          -> { ENV["ZCODE_CLI_PATH"] },
          -> { find_in_path("zcode") },
          -> { "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs" }
        ].freeze

        DEFAULT_DELIVERY_KIND = "web-remote-replayable"

        attr_reader :cli_path

        def initialize(cwd: ".", cli_path: nil, request_timeout: 60.0)
          @cwd = cwd
          @cli_path = cli_path || self.class.resolve_cli_path
          @request_timeout = request_timeout
          @mutex = Mutex.new
          @stdin = nil
          @event_handlers = []
          @pending = {}
          @next_id = 0
          @started = false
          @stdout_queue = Queue.new
        end

        def start
          @mutex.synchronize do
            return if @started
            args = @cli_path.end_with?(".cjs") ? ["node", "--experimental-sqlite", @cli_path, "app-server"] : [@cli_path, "app-server"]
            @stdin, stdout, stderr, @wait_thr = Open3.popen3(*args, chdir: @cwd)

            @stdout_thread = Thread.new(stdout) do |io|
              io.each_line do |line|
                line = line.strip
                @stdout_queue << line unless line.empty?
              end
              @stdout_queue << nil
            end

            Thread.new(stderr) { |io| io.each_line { |l| l.strip } }

            @dispatcher = Thread.new do
              while (line = @stdout_queue.pop)
                begin
                  handle_message(JSON.parse(line))
                rescue JSON::ParserError
                end
              end
            rescue => e
            end

            @started = true
          end
        end

        def stop
          @mutex.synchronize do
            return unless @started
            @started = false
            @stdin&.close rescue nil
            @stdout_thread&.join(3) rescue nil
            Process.kill("TERM", @wait_thr.pid) rescue nil
            @wait_thr&.join(5) rescue nil
            @stdin = nil
            @pending.each_value { |f| f[:error] = AppServerUnavailable.new("process exited"); f[:done] = true; f[:condition].signal }
            @pending.clear
          end
        end

        def running?
          @started && @wait_thr&.alive?
        end

        def on_notification(&handler)
          @mutex.synchronize { @event_handlers << handler }
        end

        def request(method, params = nil, timeout: nil)
          ensure_running
          future = { done: false, result: nil, error: nil, condition: ConditionVariable.new }

          @mutex.synchronize do
            @next_id += 1
            @pending[@next_id] = future
            write_line({ id: @next_id, method: method, params: params }.compact)
          end

          timeout ||= @request_timeout
          deadline = Time.now + timeout

          @mutex.synchronize do
            until future[:done]
              remaining = deadline - Time.now
              raise Ask::CodingProviders::TimeoutError, "Request timed out after #{timeout}s" if remaining <= 0
              future[:condition].wait(@mutex, remaining)
            end
          end

          raise future[:error] if future[:error]
          future[:result]
        end

        def respond(request_id, result)
          ensure_running
          @mutex.synchronize { write_line({ id: request_id, result: result }) }
        end

        # -- High-level API --

        def create_session(workspace_path, workspace_key: nil, mode: nil)
          params = { workspace: { workspacePath: workspace_path, workspaceKey: workspace_key || workspace_path } }
          params[:mode] = mode if mode
          result = request("session/create", params)
          session = result.is_a?(Hash) ? (result["session"] || result[:session] || {}) : {}
          sid = session["sessionId"] || session[:sessionId]
          raise Ask::CodingProviders::ZCode::Error, "session/create did not return sessionId" unless sid
          sid
        end

        def list_sessions(workspace_path: nil, limit: 20)
          params = { limit: limit }
          params[:workspace] = { workspacePath: workspace_path, workspaceKey: workspace_path } if workspace_path
          result = request("session/list", params)
          result.is_a?(Hash) ? (result["sessions"] || result[:sessions] || []) : []
        end

        def resume_session(session_id)
          request("session/resume", { sessionId: session_id })
        end

        def subscribe(session_id, after_seq: 0, include_snapshot: false)
          request("session/subscribe", {
            sessionId: session_id, deliveryKind: DEFAULT_DELIVERY_KIND,
            afterSeq: after_seq, includeSnapshot: include_snapshot
          })
        end

        def read_workspace_state(workspace_path)
          request("workspace/readState", {
            workspace: { workspacePath: workspace_path, workspaceKey: workspace_path }
          })
        end

        def send_message(session_id, content)
          request("session/send", { sessionId: session_id, content: content })
        end

        def get_events(session_id, after_seq:, limit: nil)
          params = { sessionId: session_id, afterSeq: after_seq }
          params[:limit] = limit if limit
          request("session/events", params)
        end

        def self.resolve_cli_path
          CLI_PATHS.each do |resolver|
            path = resolver.call
            return path if path && File.exist?(path)
          end
          raise Ask::CodingProviders::ZCode::Error,
            "Cannot find ZCode CLI. Set ZCODE_CLI_PATH, add zcode to PATH, or install ZCode."
          end

        private

        def ensure_running
          raise AppServerUnavailable, "app-server is not running. Call #start first." unless running?
        end

        def write_line(msg)
          @stdin&.puts(JSON.generate(msg))
          @stdin&.flush
        end

        def handle_message(msg)
          if msg.key?("id")
            rid = msg["id"]
            future = nil
            @mutex.synchronize { future = @pending.delete(rid) }

            if future
              @mutex.synchronize do
                if msg.key?("error")
                  future[:error] = make_error(msg["error"])
                elsif msg.key?("result")
                  future[:result] = msg["result"]
                else
                  future[:error] = Ask::CodingProviders::ZCode::Error.new("No result or error")
                end
                future[:done] = true
                future[:condition].signal
              end
              return
            end

            dispatch_notification(msg["method"], msg["params"] || {}, msg["id"]) if msg.key?("method")
            return
          end

          dispatch_notification(msg["method"], msg["params"] || {}, nil) if msg.key?("method")
        end

        def dispatch_notification(method, params, request_id)
          @event_handlers.dup.each { |h| h.call(method, params, request_id) rescue nil }
        end

        def make_error(err)
          case err["code"]
          when -32_004 then SessionUnavailable.new(err["message"])
          when -32_010 then PromptAlreadyRunning.new(err["message"])
          else Ask::CodingProviders::ZCode::Error.new("[#{err["code"]}] #{err["message"]}")
          end
        end

        def self.find_in_path(executable)
          ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
            path = File.join(dir, executable)
            return path if File.exist?(path)
          end
          nil
        end
      end
    end
  end
end
