# frozen_string_literal: true

require "securerandom"

begin
  require "ask-llm-providers"
  require "ask/agent"
rescue LoadError => e
  raise "Missing dependency for AskAgent adapter: #{e.message}. Add ask-agent and ask-llm-providers to your Gemfile."
end

begin
  require "ask/permissions"
rescue LoadError
  require "ask-permissions"
end

module Ask
  module CodingProviders
    module AskAgent
      # Approval queue that notifies callbacks when actions are submitted or
      # change status, so clients can stream approval state in real time.
      #
      # The session wires its own apply/reject/submit callbacks onto the
      # queue (see Session#build_approval); this subclass only adds
      # observation hooks on top, using its own listeners so the session's
      # on_submit (pending-tool registration) is never clobbered.
      class EmittingApprovalQueue < Ask::Permissions::ApprovalQueue
        # @param on_submit [Proc, nil] called with the new
        #   {Ask::Permissions::Action} after submission (and after the
        #   auto-approval drain)
        # @param on_status [Proc, nil] called with an
        #   {Ask::Permissions::Action} whose status changed to :approved
        #   or :rejected
        def initialize(on_submit: nil, on_status: nil, **kwargs)
          @on_action_submitted = on_submit
          @on_status = on_status
          super(**kwargs)
        end

        def submit(tool_call_id:, tool_name:, args: {}, auto_approvable: false, message: nil)
          id = super
          @on_action_submitted&.call(self[id])
          id
        end

        private

        # The base queue passes an extra argument (approval scope) to these
        # hooks; forward everything to super and only observe the result.
        def apply(action, ...)
          result = super
          @on_status&.call(action.with(status: :approved))
          result
        end

        def reject_action(action, ...)
          result = super
          @on_status&.call(action.with(status: :rejected))
          result
        end
      end

      # Adapter that wraps Ask::Agent::Session directly (in-process).
      #
      # Sessions persist across turns: each session id maps to one
      # Ask::Agent::Session instance whose conversation history accumulates.
      # Every agent event is translated and streamed to subscribers, including
      # thinking deltas, tool executions, approvals, plans, and todos. When a
      # tool queues for human approval, the turn pauses; approving or
      # rejecting from any thread continues the turn (follow-up turns run
      # inside ask-agent and their events reach the same subscribers).
      #
      # @example
      #   adapter = AskAgent::Adapter.new(
      #     model: "deepseek-v4-flash", provider: "opencode_go",
      #     approval: :require, approval_required: %w[bash write edit]
      #   )
      #   adapter.start
      #   sid = adapter.create_session("/tmp")
      #   adapter.send_and_stream(sid, "Hello") { |ev| puts ev[:type] }
      #   adapter.pending_approvals(sid) # => [{id: 1, tool_name: "bash", ...}]
      #   adapter.approve_action(sid, 1)
      class Adapter < Ask::CodingProviders::Adapter
        # Approval modes: :off disables the queue, :require gates
        # approval_required tools behind human review, :auto keeps the queue
        # (visible/inspectable) but never blocks.
        APPROVAL_OFF = :off
        APPROVAL_REQUIRE = :require
        APPROVAL_AUTO = :auto
        APPROVAL_MODES = [APPROVAL_OFF, APPROVAL_REQUIRE, APPROVAL_AUTO].freeze

        # Approval scopes this adapter accepts. :once approves only the
        # named action; :session records a session grant (applied by
        # Ask::Agent::Session before the approved action runs) so matching
        # actions later in the session are auto-approved. :project is
        # deliberately excluded: this adapter never injects project grants
        # into the queue, so accepting it would be a silent no-op.
        APPROVAL_SCOPES = %i[once session].freeze

        # How long a turn stays settled before it is considered complete
        # (protects against follow-up turns starting right after the queue
        # drains).
        SETTLE_POLL_INTERVAL = 0.05 # seconds
        SETTLE_POLLS = 4

        # @param model [String] model ID (e.g. "deepseek-v4-flash")
        # @param provider [String] provider slug (e.g. "opencode_go")
        # @param tools [Array] tool instances to make available
        # @param max_turns [Integer] max conversation turns per session
        # @param approval [Symbol] one of APPROVAL_MODES
        # @param approval_required [Array<String>] tool names gated behind
        #   human approval when approval is :require
        # @param plan_mode [Boolean] enable plan mode (exit_plan_mode tool +
        #   read-only gate until the plan is approved)
        # @param todos [Boolean] enable the todo list (todo_write tool)
        # @param session_opts [Hash] extra options passed to
        #   Ask::Agent::Session (hooks, system_prompt, compactor, ...)
        def initialize(model:, provider:, tools: [], max_turns: 25,
                       approval: APPROVAL_OFF, approval_required: nil,
                       plan_mode: false, todos: false, **session_opts)
          @model_id = model
          @provider_slug = provider
          @tools = Array(tools)
          @max_turns = max_turns
          @approval = approval
          @approval_required = Array(approval_required)
          @plan_mode = !!plan_mode
          @todos = !!todos
          @session_opts = session_opts
          @started = false
          @provider = nil
          @sessions = {}
          @mutex = Mutex.new
          unless APPROVAL_MODES.include?(approval)
            raise ArgumentError, "approval must be one of #{APPROVAL_MODES.inspect}, got #{approval.inspect}"
          end
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
          @mutex.synchronize do
            @sessions.each_value { |entry| entry[:session]&.abort }
            @sessions.clear
          end
          @started = false
          @provider = nil
        end

        def running?
          @started
        end

        # Create a new conversation session for a workspace.
        # Returns a session ID (UUID).
        #
        # @param workspace_path [String] working directory
        # @param mode [String, nil] permission mode
        # @param model [String, nil] model override for this session
        # @param system_prompt [String, nil] system prompt override for this
        #   session (takes precedence over any system_prompt in session_opts)
        # @param agent [String, nil] declarative agent name (ask-agent
        #   convention: agents/<name>/agent.rb + instructions.md, discovered
        #   from the workspace's working directory). When given, the session
        #   is built via Ask::Agent.new so the definition's tools, skills,
        #   and instructions apply; the harness-level options (model,
        #   system_prompt, approval, plan mode, todos) still win.
        def create_session(workspace_path, mode: nil, model: nil, system_prompt: nil, agent: nil)
          ensure_started
          sid = "sess_#{SecureRandom.uuid}"
          @mutex.synchronize do
            @sessions[sid] = {
              workspace: workspace_path,
              mode: mode,
              model: model || @model_id,
              system_prompt: system_prompt,
              agent: agent,
              created_at: Time.now,
              session: nil,
              subscribers: [],
              seq: 0,
              turn_active: false
            }
          end
          sid
        end

        def resume_session(session_id)
          ensure_started
          entry = @sessions[session_id]
          return {} unless entry
          {
            "session_id" => session_id,
            "workspace" => entry[:workspace],
            "model" => entry[:model],
            "created_at" => entry[:created_at].iso8601
          }
        end

        def list_sessions(workspace_path: nil, limit: 20)
          ensure_started
          @mutex.synchronize do
            @sessions
              .select { |_sid, e| workspace_path.nil? || e[:workspace] == workspace_path }
              .sort_by { |sid, e| [e[:created_at], sid] }
              .reverse
              .first(limit)
              .map { |sid, e| { session_id: sid, workspace: e[:workspace], created_at: e[:created_at].iso8601 } }
          end
        end

        def subscribe(session_id, after_seq: 0)
          ensure_started
          { "eventSeq" => session_entry(session_id)[:seq] }
        end

        def send_message(session_id, content, attachments: nil)
          ensure_started
          result = nil
          send_and_stream(session_id, content, attachments: attachments) do |ev|
            result = ev.dig(:payload, "response") if ev[:type] == "turn.completed"
          end
          { "response" => result }
        end

        # Send a message and stream translated events to the block.
        #
        # Runs the session's loop synchronously; when tools queue for
        # approval the turn pauses and this method waits (up to turn_timeout)
        # for the queue to drain, so subscribers receive the full turn —
        # including follow-up turns that run when approvals resolve.
        #
        # @yield [Hash] events with :type, :seq, :payload
        def send_and_stream(session_id, content, turn_timeout: 600.0, attachments: nil, &block)
          return enum_for(:send_and_stream, session_id, content, turn_timeout: turn_timeout, attachments: attachments) unless block
          ensure_started

          entry = session_entry(session_id)
          session = (entry[:session] ||= build_session(entry))

          subscription = subscribe_session(entry, &block)
          emit(entry, { type: "turn.started", seq: next_seq(entry), payload: { "sessionId" => session_id } })

          begin
            result = run_with_approvals(entry, session, content, attachments: attachments, turn_timeout: turn_timeout)
            if session.abort_requested?
              emit(entry, { type: "turn.aborted", seq: next_seq(entry), payload: { "sessionId" => session_id } })
            else
              emit(entry, {
                type: "turn.completed", seq: next_seq(entry),
                payload: {
                  "response" => (result || accumulated_text(entry)).to_s,
                  "sessionId" => session_id,
                  "tokenCount" => session.total_input_tokens + session.total_output_tokens
                }
              })
            end
          rescue => e
            emit(entry, {
              type: "turn.failed", seq: next_seq(entry),
              payload: { "error" => { "message" => e.message }, "sessionId" => session_id }
            })
          ensure
            unsubscribe_session(entry, subscription)
            entry[:turn_active] = false
          end
          nil
        end

        # ── Approval controls ──

        # Approve one queued tool action. Continues the turn (follow-up
        # turns run in this thread and stream to active subscribers).
        #
        # @param scope [Symbol] :once (default) approves only this action;
        #   :session records a session grant for matching later actions.
        #   :project raises ArgumentError (no project grants injected).
        # @raise [ArgumentError] for :project or unknown scopes
        # @return [Array<Ask::Permissions::Action>]
        def approve_action(session_id, action_id, scope: :once)
          validate_approval_scope!(scope)
          queue = approval_queue(session_id)
          queue ? queue.approve(action_id, scope: scope) : []
        end

        def reject_action(session_id, action_id)
          queue = approval_queue(session_id)
          queue ? queue.reject(action_id) : []
        end

        # Approve all pending tool actions.
        #
        # @param scope [Symbol] see {#approve_action}
        # @raise [ArgumentError] for :project or unknown scopes
        def approve_all(session_id, scope: :once)
          validate_approval_scope!(scope)
          queue = approval_queue(session_id)
          queue ? queue.approve_all(scope: scope) : []
        end

        def reject_all(session_id)
          queue = approval_queue(session_id)
          queue ? queue.reject_all : []
        end

        # Actions still awaiting a decision, as plain hashes.
        def pending_approvals(session_id)
          queue = approval_queue(session_id)
          return [] unless queue
          queue.pending_actions.map { |a| action_hash(a) }
        end

        # The pending plan awaiting approval (plan mode), or nil.
        def pending_plan(session_id)
          session = session_entry(session_id)[:session]
          return nil unless session&.plan_queue
          action = session.plan_queue.pending_actions.first
          action && action_hash(action)
        end

        # Approve / reject the proposed plan (plan mode).
        def approve_plan(session_id)
          session_entry(session_id)[:session]&.plan_queue&.approve_all || []
        end

        def reject_plan(session_id)
          session_entry(session_id)[:session]&.plan_queue&.reject_all || []
        end

        # Abort the current turn. The loop exits at the next checkpoint and
        # the stream emits turn.aborted.
        def abort(session_id)
          session_entry(session_id)[:session]&.abort
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

        def session_directory(session_id)
          entry = @mutex.synchronize { @sessions[session_id] }
          entry && entry[:workspace]
        end

        # Message history for a session, newest first. Empty for unknown or
        # not-yet-run sessions.
        def session_history(session_id, limit: 100)
          entry = @mutex.synchronize { @sessions[session_id] }
          return [] unless entry
          session = entry[:session]
          return [] unless session
          session.messages.last(limit).reverse.map do |m|
            { text: m.content.to_s, role: m.role.to_s, origin: "ask_agent" }
          end
        end

        # Build an AskAgent adapter from config.
        # Reads ASK_AGENT_MODEL, ASK_AGENT_LLM_PROVIDER, ASK_AGENT_MAX_TURNS
        # from ENV.
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

        def session_entry(session_id)
          entry = @mutex.synchronize { @sessions[session_id] }
          raise ArgumentError, "Unknown session: #{session_id}" unless entry
          entry
        end

        def approval_queue(session_id)
          session_entry(session_id)[:session]&.approval_queue
        end

        # Scope validation runs before the session/queue lookup so :project
        # (and unknown scopes) raise even when no queue exists — never a
        # silent no-op.
        def validate_approval_scope!(scope)
          return scope if APPROVAL_SCOPES.include?(scope)
          if scope == :project
            raise ArgumentError,
                  "approval scope :project is not supported by the AskAgent adapter " \
                  "(project grants are not injected here; use :once or :session)"
          end
          raise ArgumentError,
                "approval scope must be one of #{APPROVAL_SCOPES.inspect} " \
                "(this adapter does not support :project), got #{scope.inspect}"
        end

        # ── Session construction ──

        def build_session(entry)
          session = entry[:agent] ? build_agent_session(entry) : build_plain_session(entry)
          session.on_event { |event| translate_event(entry, session, event) }
          session
        end

        # Build a session from a declarative agent definition (ask-agent
        # convention). The definition's tools, skills (agent_dir), and
        # instructions apply; harness-level options win where set. Agents
        # are discovered from the working directory (the harness runs the
        # session inside its workspace).
        #
        # The emitting approval queue is passed through Ask::Agent.new's
        # opts, so Session#build_approval wires it with the session's
        # apply/reject/register callbacks — approval events stream exactly
        # like the plain path.
        def build_agent_session(entry)
          queue = emitting_queue(entry)
          opts = {
            approval: approval_config(queue),
            plan_mode: @plan_mode,
            todos: @todos,
            max_turns: @max_turns,
            # Caller options win over the definition; a nil model lets the
            # definition's own model apply.
            model: (entry[:model] unless entry[:model] == @model_id)
          }.compact
          opts[:system_prompt] = entry[:system_prompt] if entry[:system_prompt]
          Ask::Agent.new(entry[:agent], **opts)
        end

        # Build the default session (no declarative agent).
        def build_plain_session(entry)
          prompt = entry[:system_prompt] || @session_opts[:system_prompt]
          chat = build_chat(entry[:model], prompt)

          Ask::Agent::Session.new(
            model: chat,
            tools: @tools,
            max_turns: @max_turns,
            approval: approval_config(emitting_queue(entry)),
            plan_mode: @plan_mode,
            todos: @todos,
            **@session_opts
          )
        end

        def emitting_queue(entry)
          EmittingApprovalQueue.new(
            on_submit: ->(a) { emit_approval(entry, a, :pending) },
            on_status: ->(a) { emit_approval(entry, a, a.status) }
          )
        end

        def approval_config(queue)
          case @approval
          when APPROVAL_REQUIRE then { queue: queue, require_approval: @approval_required }
          when APPROVAL_AUTO then { queue: queue }
          when APPROVAL_OFF then nil
          else
            raise ArgumentError, "approval must be one of #{APPROVAL_MODES.inspect}, got #{@approval.inspect}"
          end
        end



        def build_chat(model_id, system_prompt = nil)
          chat = Ask::Agent::Chat.new(
            model: model_id,
            provider: @provider_slug,
            tools: @tools
          )
          chat.with_instructions(system_prompt) if system_prompt
          # Inject pre-configured provider to bypass Ask::Auth.resolve
          chat.instance_variable_set(:@provider, @provider)
          chat
        end

        # ── Turn lifecycle ──

        # Run the agent loop, then wait — up to turn_timeout — for the turn
        # to fully settle: idle, no pending tools, and an empty approval
        # queue. Approvals resolve from other threads; each resolution may
        # trigger follow-up turns inside ask-agent (via
        # complete_pending_tool), whose events stream to the same
        # subscribers. The settle grace period absorbs the gap between the
        # queue draining and a follow-up turn starting.
        def run_with_approvals(entry, session, content, attachments:, turn_timeout:)
          result = session.run(content, attachments: attachments)
          entry[:turn_active] = true
          deadline = monotonic + turn_timeout
          settle_count = 0

          loop do
            return result if session.abort_requested?
            if turn_settled?(session, entry)
              settle_count += 1
              return result if settle_count >= SETTLE_POLLS
            else
              settle_count = 0
            end

            if monotonic > deadline
              session.abort
              raise Timeout::Error, "Turn timed out after #{turn_timeout}s"
            end
            sleep SETTLE_POLL_INTERVAL
          end
        end

        def turn_settled?(session, _entry)
          queue = session.approval_queue
          !session.running? &&
            !session.pending_tools? &&
            (queue.nil? || queue.pending_actions.empty?)
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # ── Event translation (ask-agent events → adapter events) ──

        def translate_event(entry, session, event)
          payload = { "sessionId" => session.id }
          case event
          when Ask::Agent::Events::TextDelta
            emit(entry, { type: "model.streaming", seq: next_seq(entry), payload: payload.merge("delta" => event.content) })
          when Ask::Agent::Events::ThinkingDelta
            emit(entry, { type: "model.thinking", seq: next_seq(entry), payload: payload.merge("delta" => event.content) })
          when Ask::Agent::Events::ToolExecutionStart
            emit(entry, {
              type: "tool.use", seq: next_seq(entry),
              payload: payload.merge("toolName" => event.name, "input" => event.arguments, "toolCallId" => event.id)
            })
          when Ask::Agent::Events::ToolExecutionUpdate
            emit(entry, {
              type: "tool.delta", seq: next_seq(entry),
              payload: payload.merge("toolName" => event.name, "toolCallId" => event.id, "partial" => event.partial_result)
            })
          when Ask::Agent::Events::ToolExecutionEnd
            emit(entry, {
              type: "tool.result", seq: next_seq(entry),
              payload: payload.merge(
                "toolName" => event.name, "toolCallId" => event.id,
                "output" => tool_output(event.result),
                "isError" => !!event.is_error,
                "durationMs" => event.duration_ms
              )
            })
          when Ask::Agent::Events::TodoUpdated
            emit(entry, { type: "todos.updated", seq: next_seq(entry), payload: payload.merge("todos" => event.todos) })
          when Ask::Agent::Events::PlanProposed
            emit(entry, { type: "plan.proposed", seq: next_seq(entry), payload: payload.merge("plan" => event.plan) })
          when Ask::Agent::Events::PlanApproved
            emit(entry, { type: "plan.approved", seq: next_seq(entry), payload: payload.merge("plan" => event.plan) })
          when Ask::Agent::Events::PlanRejected
            emit(entry, { type: "plan.rejected", seq: next_seq(entry), payload: payload.merge("plan" => event.plan) })
          when Ask::Agent::Events::Error
            emit(entry, { type: "error", seq: next_seq(entry), payload: payload.merge("error" => { "message" => event.error.to_s }) })
          end
        end

        def tool_output(result)
          return result.to_s if result.nil?
          return result.to_s if result.respond_to?(:to_s) && !result.respond_to?(:data) && !result.respond_to?(:message)
          if result.respond_to?(:ok?)
            result.ok? ? result.data.to_s : result.message.to_s
          else
            result.to_s
          end
        end

        # ── Subscription / emission ──

        def subscribe_session(entry, &block)
          @mutex.synchronize { entry[:subscribers] << block }
          block
        end

        def unsubscribe_session(entry, subscription)
          @mutex.synchronize { entry[:subscribers].delete(subscription) }
        end

        def emit(entry, event)
          if event[:type] == "model.streaming"
            @mutex.synchronize do
              entry[:streaming_text] = entry[:streaming_text].to_s + event.dig(:payload, "delta").to_s
            end
          end
          subscribers = @mutex.synchronize { entry[:subscribers].dup }
          subscribers.each { |sub| sub.call(event) }
        end

        def emit_approval(entry, action, status)
          payload = {
            "sessionId" => entry[:session]&.id,
            "actionId" => action.id,
            "toolName" => action.tool_name,
            "args" => action.args,
            "message" => action.message,
            "autoApprovable" => action.auto_approvable,
            "status" => status.to_s
          }
          type = status == :pending ? "approval.required" : "approval.updated"
          emit(entry, { type: type, seq: next_seq(entry), payload: payload })
        end

        def accumulated_text(entry)
          @mutex.synchronize { entry[:streaming_text].to_s }
        end

        def action_hash(action)
          {
            "id" => action.id,
            "tool_call_id" => action.tool_call_id,
            "tool_name" => action.tool_name,
            "args" => action.args,
            "auto_approvable" => action.auto_approvable,
            "status" => action.status.to_s,
            "message" => action.message
          }
        end

        def next_seq(entry)
          @mutex.synchronize { entry[:seq] += 1 }
        end
      end
    end
  end
end

Ask::CodingProviders.register_adapter(:ask_agent, Ask::CodingProviders::AskAgent::Adapter)
