# frozen_string_literal: true

require "json"
require "open3"

module Ask
  module CodingProviders
    module Codex
      # JSON-RPC 2.0 client for the Codex app-server (stdio transport).
      #
      # Protocol: https://learn.chatgpt.com/docs/app-server
      #
      # Spawns `codex app-server` as a subprocess and communicates over stdio
      # using newline-delimited JSON.
      class AppServerClient
        CLI_PATHS = [
          -> { ENV["CODEX_CLI_PATH"] },
          -> { find_in_path("codex") },
        ].freeze

        attr_reader :cli_path

        def initialize(cwd: ".", cli_path: nil, request_timeout: 30.0, model: nil, model_provider: nil)
          @cwd = cwd
          @cli_path = cli_path || self.class.resolve_cli_path
          @request_timeout = request_timeout
          @model = model
          @model_provider = model_provider
          @extra_args = build_extra_args
          @mutex = Mutex.new
          @stdin = nil
          @event_handlers = []
          @pending = {}
          @next_id = 0
          @started = false
          @stdout_queue = Queue.new
          @initialized = false
        end

        def start
          @mutex.synchronize do
            return if @started
            @stdin, stdout, stderr, @wait_thr = Open3.popen3(@cli_path, "app-server", "--stdio", *@extra_args, chdir: @cwd)

            @stdout_thread = Thread.new(stdout) do |io|
              io.each_line do |line|
                line = line.strip
                @stdout_queue << line unless line.empty?
              end
              @stdout_queue << nil
            end

            # Drain stderr to avoid deadlocks
            Thread.new(stderr) { |io| io.each_line { |_| } }

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
            @pending.each_value { |f| f[:error] = Error.new("process exited"); f[:done] = true; f[:condition].signal }
            @pending.clear
          end
        end

        def running?
          @started && @wait_thr&.alive?
        end

        def on_notification(&handler)
          @mutex.synchronize { @event_handlers << handler }
        end

        # Perform the JSON-RPC initialize handshake.
        # Must be called before any other request.
        def initialize!
          result = request("initialize", {
            protocolVersion: "0.1.0",
            clientInfo: { name: "ask-coder", version: "0.1.0" },
            capabilities: {}
          })
          @initialized = true
          result
        end

        def send_initialized
          return unless @initialized
          # The 'initialized' notification is a JSON-RPC 2.0 notification (no id)
          @mutex.synchronize do
            write_line({ jsonrpc: "2.0", method: "initialized", params: {} })
          end
        end

        # -- High-level API --

        def thread_start(cwd: nil)
          ensure_initialized
          params = {
            cwd: cwd || @cwd,
            approvalPolicy: "never",
            sandbox: "read-only"
          }
          result = request("thread/start", params)
          result&.dig("thread") || result&.dig(:thread) || {}
        end

        def thread_resume(thread_id)
          ensure_initialized
          request("thread/resume", { threadId: thread_id })
        end

        def turn_start(thread_id, input)
          ensure_initialized
          input_items = input.is_a?(Array) ? input : [{ type: "text", text: input.to_s }]
          request("turn/start", {
            threadId: thread_id,
            input: input_items,
            cwd: @cwd
          })
        end

        def thread_list(limit: 20)
          ensure_initialized
          request("thread/list", { limit: limit })
        end

        def read_workspace_state
          ensure_initialized
          request("config/read", {})
        end

        def model_list
          ensure_initialized
          request("model/list", {})
        end

        def respond(request_id, result)
          ensure_initialized
          @mutex.synchronize { write_line({ id: request_id, result: result }) }
        end

        def request(method, params = nil, timeout: nil)
          ensure_running
          future = { done: false, result: nil, error: nil, condition: ConditionVariable.new }

          @mutex.synchronize do
            @next_id += 1
            @pending[@next_id] = future
            write_line({ jsonrpc: "2.0", id: @next_id, method: method, params: params }.compact)
          end

          timeout ||= @request_timeout
          deadline = Time.now + timeout

          @mutex.synchronize do
            until future[:done]
              remaining = deadline - Time.now
              raise TimeoutError, "Request timed out after #{timeout}s" if remaining <= 0
              future[:condition].wait(@mutex, remaining)
            end
          end

          raise future[:error] if future[:error]
          future[:result]
        end

        def self.resolve_cli_path
          CLI_PATHS.each do |resolver|
            path = resolver.call
            return path if path && File.exist?(path)
          end
          # Check the npm global install path
          npm_path = File.expand_path("~/.asdf/installs/nodejs/*/lib/node_modules/@openai/codex/bin/codex.js")
          Dir[npm_path].each { |p| return p if File.exist?(p) }
          raise Error, "Cannot find Codex CLI. Set CODEX_CLI_PATH or install Codex."
        end

        private

        def build_extra_args
          args = []
          args += ["-c", "model=#{@model}"] if @model
          args += ["-c", "model_provider=#{@model_provider}"] if @model_provider
          args
        end

        def ensure_running
          raise Error, "app-server is not running. Call #start first." unless running?
        end

        def ensure_initialized
          ensure_running
          raise Error, "Not initialized. Call #initialize! first." unless @initialized
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
                  future[:error] = Error.new("[#{msg["error"]["code"]}] #{msg["error"]["message"]}")
                elsif msg.key?("result")
                  future[:result] = msg["result"]
                else
                  future[:error] = Error.new("No result or error")
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
