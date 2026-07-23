# frozen_string_literal: true

require "securerandom"

module Ask
  module CodingProviders
    module AskAgent
      # Adapter that wraps Ask::Agent::Session directly (in-process).
      #
      # No app-server, no external binary — sessions run in the same process.
      # Perfect for deployments where running a separate process is impractical.
      #
      # @example
      #   adapter = AskAgent::Adapter.new(model: "deepseek-v4-flash", provider: "opencode_go")
      #   adapter.start
      #   sid = adapter.create_session("/tmp")
      #   adapter.send_and_stream(sid, "Hello") { |ev| puts ev }
      class Adapter < Ask::CodingProviders::Adapter
        # @param model [String] model ID (e.g. "deepseek-v4-flash")
        # @param provider [String] provider slug (e.g. "opencode_go")
        # @param tools [Array] tool instances to make available
        # @param max_turns [Integer] max conversation turns per session
        def initialize(model:, provider:, tools: [], max_turns: 25, **session_opts)
          # Lazy require — these gems are optional for the gem but required for this adapter
          begin
            require "ask-llm-providers"
            require "ask/agent"
          rescue LoadError => e
            raise "Missing dependency for AskAgent adapter: #{e.message}. Add ask-agent and ask-llm-providers to your Gemfile."
          end

          @model_id = model
          @provider_slug = provider
          @tools = tools
          @max_turns = max_turns
          @session_opts = session_opts
          @started = false
          @provider = nil
        end

  def start
    return if @started
    klass = Ask::Provider.resolve(@provider_slug)
    compat = klass.respond_to?(:compat_config) ? klass.compat_config : {}
    api_key = ENV[compat[:alternate_env].to_s] || ENV[compat[:api_key_env].to_s] || ENV["#{@provider_slug.upcase}_API_KEY"]
    @provider = klass.new(api_key: api_key)
    @started = true
  end

        def stop
          @started = false
          @provider = nil
        end

        def running?
          @started
        end

        # Create a new conversation session.
        # The workspace_path is noted but not used by in-process agent.
        # Returns a session ID (UUID).
        def create_session(workspace_path, mode: nil)
          ensure_started
          sid = "sess_#{SecureRandom.uuid}"
          @sessions ||= {}
          @sessions[sid] = { workspace: workspace_path, mode: mode, created_at: Time.now }
          sid
        end

        def resume_session(session_id)
          ensure_started
          @sessions&.dig(session_id) || {}
        end

        def subscribe(session_id, after_seq: 0)
          ensure_started
          { "eventSeq" => 0 }
        end

        def send_message(session_id, content)
          ensure_started
          # Run synchronously — returns when done
          result = run_session(session_id, content)
          { "response" => result }
        end

        def send_and_stream(session_id, content, turn_timeout: 600.0, &block)
          return enum_for(:send_and_stream, session_id, content, turn_timeout: turn_timeout) unless block
          ensure_started

          # Build the ask-agent chat with our pre-configured provider
          chat = build_chat
          session = Ask::Agent::Session.new(
            model: chat,
            max_turns: @max_turns,
            **@session_opts
          )

          # Emit turn.started
          block.call({ type: "turn.started", seq: 1, payload: { "sessionId" => session_id } })

          # Wire streaming events
          session.on_event do |event|
            case event
            when Ask::Agent::Events::TextDelta
              block.call({
                type: "model.streaming", seq: 2,
                payload: { "delta" => event.content, "sessionId" => session_id }
              })
            end
          end

          begin
            result = session.run(content)
            block.call({
              type: "turn.completed", seq: 3,
              payload: { "response" => result, "sessionId" => session_id,
                         "tokenCount" => session.total_input_tokens + session.total_output_tokens }
            })
          rescue => e
            block.call({
              type: "turn.failed", seq: 3,
              payload: { "error" => { "message" => e.message }, "sessionId" => session_id }
            })
          end
        end

        def get_events(session_id, after_seq:, limit: nil)
          { "events" => [] }
        end

        def respond(request_id, result)
          # No reverse requests in basic mode
        end

	  def get_workspace_state(workspace_path)
	    # No workspace state to report
	    {}
	  end

	  # Build an AskAgent adapter from config.
	  # Reads ASK_AGENT_MODEL, ASK_AGENT_LLM_PROVIDER, ASK_AGENT_MAX_TURNS from ENV.
	  def self.from_config(model: nil, llm_provider: nil, max_turns: nil, **)
	    new(
	      model: model || ENV.fetch("ASK_AGENT_MODEL", "deepseek-v4-flash"),
	      provider: llm_provider || ENV.fetch("ASK_AGENT_LLM_PROVIDER", "opencode_go"),
	      max_turns: (max_turns || ENV.fetch("ASK_AGENT_MAX_TURNS", "10")).to_i
	    )
	  end

	  private

        def ensure_started
          raise "Adapter not started. Call #start first." unless @started
        end

        def build_chat
          chat = Ask::Agent::Chat.new(
            model: @model_id,
            provider: @provider_slug,
            tools: @tools
          )
          # Inject pre-configured provider to bypass Ask::Auth.resolve
          chat.instance_variable_set(:@provider, @provider)
          chat
        end

        def run_session(session_id, content)
          chat = build_chat
          session = Ask::Agent::Session.new(
            model: chat,
            max_turns: @max_turns,
            **@session_opts
          )
          session.run(content)
        end
      end
    end
  end
end

Ask::CodingProviders.register_adapter(:ask_agent, Ask::CodingProviders::AskAgent::Adapter)
