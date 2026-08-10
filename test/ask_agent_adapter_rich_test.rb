# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"

# Integration tests for the AskAgent adapter with a REAL Ask::Agent::Session
# and a stubbed Chat (no network). Covers the rich event stream: streaming
# text, thinking, tool executions, approvals with follow-up turns, plan
# mode, todos, abort, and session persistence across turns.
class AskAgentAdapterRichTest < Minitest::Test
  # A streamed chunk as yielded by Chat#ask.
  StreamChunk = Struct.new(:content, :thinking, :tool_calls, keyword_init: true) do
    def tool_call? = !tool_calls.nil? && !tool_calls.empty?
  end

  ResponseMessage = Data.define(:content, :tool_calls, :tool_results, :thinking, :input_tokens, :output_tokens, :cost) do
    def initialize(content:, tool_calls: {}, tool_results: {}, thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil)
      super(content: content, tool_calls: tool_calls, tool_results: tool_results, thinking: thinking,
            input_tokens: input_tokens, output_tokens: output_tokens, cost: cost)
    end
    def tool_call? = !tool_calls.empty?
    def to_s = content.to_s
  end

  class EchoTool < Ask::Tool
    description "Echo the given text back"
    param :text, type: :string, required: true

    def execute(text:)
      Ask::Result.ok(data: { echoed: text })
    end
  end

  class EchoApprovalTool < Ask::Tool
    description "Echo with approval"
    approval_required true
    param :text, type: :string, required: true

    def execute(text:)
      Ask::Result.ok(data: { echoed: text })
    end
  end

  FakeProvider = Class.new do
    def self.compat_config = {}
    def initialize(api_key:); end
  end


  def setup
    Ask::Provider.stubs(:resolve).with("opencode_go").returns(FakeProvider)
    @adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash",
      provider: "opencode_go",
      max_turns: 5
    )
    @adapter.start
  end

  def teardown
    @adapter&.stop
  end

  # Build a chat stub whose ask() streams chunks (when given a block) and
  # returns responses in sequence. Messages accumulate so session history
  # works across turns.
  def build_chat_stub(sequence: [])
    messages = []
    stub = Object.new
    stub.define_singleton_method(:model) { "deepseek-v4-flash" }
    stub.define_singleton_method(:model_id) { "deepseek-v4-flash" }
    stub.define_singleton_method(:messages) { messages }
    stub.define_singleton_method(:with_instructions) { |_| stub }
    stub.define_singleton_method(:reset_messages!) { messages.clear }
    stub.define_singleton_method(:add_message) do |role:, content: nil, tool_call_id: nil, tool_calls: nil, attachments: nil|
      messages << Ask::Message.new(role: role, content: content, tool_call_id: tool_call_id, tool_calls: tool_calls)
    end
    stub.define_singleton_method(:ask) do |_message, attachments: nil, &block|
      # The real Chat records the user message when ask is called; the stub
      # mirrors that so session history accumulates across turns.
      unless _message.to_s.empty?
        messages << Ask::Message.new(role: :user, content: _message)
      end
      response = sequence.shift || sequence.last
      if block && response
        chunks = response.thinking.to_s.empty? ? [] : [StreamChunk.new(content: nil, thinking: response.thinking)]
        if response.content.to_s.length > 0
          chunks << StreamChunk.new(content: response.content, thinking: nil)
        end
        chunks << StreamChunk.new(content: "", thinking: nil, tool_calls: response.tool_calls) unless response.tool_calls.empty?
        chunks.each { |c| block.call(c) }
      end
      response
    end
    Ask::Agent::Chat.stubs(:new).returns(stub)
    stub
  end

  def stub_tool_call(id: "call_1", name: "echo", arguments: '{"text":"hi"}')
    Ask::Agent::ToolCallInfo.new(id: id, name: name, arguments: arguments)
  end

  def run_turn(adapter, sid, prompt, timeout: 15)
    events = []
    queue = Queue.new
    error = nil
    thread = Thread.new do
      begin
        adapter.send_and_stream(sid, prompt, turn_timeout: timeout) do |ev|
          events << ev
          queue << ev
        end
      rescue => e
        error = e
        queue << { type: "THREAD_ERROR", error: "#{e.class}: #{e.message}", backtrace: e.backtrace.first(3) }
      end
    end
    thread.define_singleton_method(:error) { error }
    [events, queue, thread]
  end

  def wait_for(queue, type, timeout: 10)
    deadline = Time.now + timeout
    loop do
      ev = queue.pop(timeout: 0.2) rescue nil
      return ev if ev && ev[:type] == type
      raise "Timed out waiting for #{type}" if Time.now > deadline
    end
  end

  # ── Streaming text ──

  def test_simple_chat_streams_text_and_completes
    build_chat_stub(sequence: [ResponseMessage.new(content: "Hello there")])
    sid = @adapter.create_session("/tmp")

    events, _queue, thread = run_turn(@adapter, sid, "Say hi")
    thread.join(15)
    refute thread.alive?, "turn should finish"

    types = events.map { |e| e[:type] }
    assert_includes types, "turn.started"
    assert_includes types, "model.streaming"
    assert_includes types, "turn.completed"

    deltas = events.select { |e| e[:type] == "model.streaming" }.map { |e| e.dig(:payload, "delta") }.join
    assert_equal "Hello there", deltas
    completed = events.find { |e| e[:type] == "turn.completed" }
    assert_equal "Hello there", completed.dig(:payload, "response")
  end

  def test_thinking_deltas_are_translated
    build_chat_stub(sequence: [ResponseMessage.new(content: "Final answer", thinking: "Let me think...")])
    sid = @adapter.create_session("/tmp")

    events, _queue, thread = run_turn(@adapter, sid, "Think hard")
    thread.join(15)

    thinking = events.select { |e| e[:type] == "model.thinking" }.map { |e| e.dig(:payload, "delta") }.join
    assert_includes thinking, "Let me think..."
  end

  # ── Tool execution ──

  def test_tool_execution_streams_use_and_result
    build_chat_stub(sequence: [
      ResponseMessage.new(content: "", tool_calls: { "call_1" => stub_tool_call } ),
      ResponseMessage.new(content: "echoed done")
    ])
    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5,
      tools: [EchoTool.new]
    )
    adapter.start
    sid = adapter.create_session("/tmp")

    events, _queue, thread = run_turn(adapter, sid, "Echo hi")
    thread.join(15)

    use = events.find { |e| e[:type] == "tool.use" }
    refute_nil use, "expected tool.use, got #{events.map { |e| e[:type] }}"
    assert_equal "echo", use.dig(:payload, "toolName")
    assert_includes use.dig(:payload, "input").to_s, "hi"

    result = events.find { |e| e[:type] == "tool.result" }
    refute_nil result
    assert_equal "echo", result.dig(:payload, "toolName")
    assert_includes result.dig(:payload, "output").to_s, "hi"
    assert_equal false, result.dig(:payload, "isError")

    assert events.any? { |e| e[:type] == "turn.completed" }
  ensure
    adapter&.stop
  end

  # ── Approvals ──

  def test_approval_flow_requires_then_approves
    build_chat_stub(sequence: [
      ResponseMessage.new(content: "", tool_calls: { "call_1" => stub_tool_call(name: "echo_approval") }),
      ResponseMessage.new(content: "approved and done")
    ])
    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5,
      tools: [EchoApprovalTool.new],
      approval: :require
    )
    adapter.start
    sid = adapter.create_session("/tmp")

    events, queue, thread = run_turn(adapter, sid, "Echo with approval", timeout: 15)

    required = wait_for(queue, "approval.required")
    assert_equal "echo_approval", required.dig(:payload, "toolName")
    action_id = required.dig(:payload, "actionId")
    assert_equal "pending", required.dig(:payload, "status")

    pending = adapter.pending_approvals(sid)
    assert_equal 1, pending.size
    assert_equal action_id, pending.first["id"]

    # Approve from the main thread — the follow-up turn streams to the
    # still-open subscription.
    adapter.approve_action(sid, action_id)


    thread.join(15)
    refute thread.alive?, "turn should finish after approval"

    types = events.map { |e| e[:type] }
    assert_includes types, "approval.updated"
    updated = events.find { |e| e[:type] == "approval.updated" }
    assert_equal "approved", updated.dig(:payload, "status")
    assert_includes types, "turn.completed"
    assert_empty adapter.pending_approvals(sid)
  ensure
    adapter&.stop
  end

  def test_approval_reject_notifies_and_completes
    build_chat_stub(sequence: [
      ResponseMessage.new(content: "", tool_calls: { "call_1" => stub_tool_call(name: "echo_approval") }),
      ResponseMessage.new(content: "rejected, moving on")
    ])
    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5,
      tools: [EchoApprovalTool.new],
      approval: :require
    )
    adapter.start
    sid = adapter.create_session("/tmp")

    events, queue, thread = run_turn(adapter, sid, "Echo with approval", timeout: 15)
    required = wait_for(queue, "approval.required")
    adapter.reject_action(sid, required.dig(:payload, "actionId"))
    thread.join(15)

    updated = events.find { |e| e[:type] == "approval.updated" }
    assert_equal "rejected", updated.dig(:payload, "status")
    assert events.any? { |e| e[:type] == "turn.completed" }
  ensure
    adapter&.stop
  end

  def test_approval_required_list_gates_tools_by_rule
    build_chat_stub(sequence: [
      ResponseMessage.new(content: "", tool_calls: { "call_1" => stub_tool_call }),
      ResponseMessage.new(content: "done")
    ])
    # echo is not approval-required by class, but the rule list gates it
    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5,
      tools: [EchoTool.new],
      approval: :require, approval_required: ["echo"]
    )
    adapter.start
    sid = adapter.create_session("/tmp")

    events, queue, thread = run_turn(adapter, sid, "Echo", timeout: 15)
    wait_for(queue, "approval.required")
    adapter.approve_all(sid)
    thread.join(15)

    assert events.any? { |e| e[:type] == "turn.completed" }
    assert_empty adapter.pending_approvals(sid)
  ensure
    adapter&.stop
  end

  # ── Plan mode ──

  def test_plan_mode_proposes_then_approves
    build_chat_stub(sequence: [
      ResponseMessage.new(content: "", tool_calls: { "call_1" => stub_tool_call(name: "exit_plan_mode", arguments: '{"plan":"Step 1: refactor, Step 2: test"}') }),
      ResponseMessage.new(content: "plan approved, work done")
    ])
    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5,
      tools: [EchoTool.new],
      plan_mode: true
    )
    adapter.start
    sid = adapter.create_session("/tmp")

    events, queue, thread = run_turn(adapter, sid, "Plan a refactor", timeout: 15)

    proposed = wait_for(queue, "plan.proposed")
    assert_includes proposed.dig(:payload, "plan"), "Step 1"

    pending_plan = adapter.pending_plan(sid)
    refute_nil pending_plan, "plan should be pending"

    adapter.approve_plan(sid)
    thread.join(15)

    types = events.map { |e| e[:type] }
    assert_includes types, "plan.approved"
    assert_includes types, "turn.completed"
  ensure
    adapter&.stop
  end

  def test_plan_mode_reject
    build_chat_stub(sequence: [
      ResponseMessage.new(content: "", tool_calls: { "call_1" => stub_tool_call(name: "exit_plan_mode", arguments: '{"plan":"Bad plan"}') }),
      ResponseMessage.new(content: "plan rejected")
    ])
    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5,
      tools: [EchoTool.new],
      plan_mode: true
    )
    adapter.start
    sid = adapter.create_session("/tmp")

    events, queue, thread = run_turn(adapter, sid, "Plan something", timeout: 15)
    wait_for(queue, "plan.proposed")
    adapter.reject_plan(sid)
    thread.join(15)

    assert events.any? { |e| e[:type] == "plan.rejected" }
    assert events.any? { |e| e[:type] == "turn.completed" }
  ensure
    adapter&.stop
  end

  # ── Todos ──

  def test_todo_updates_are_streamed
    build_chat_stub(sequence: [
      ResponseMessage.new(content: "", tool_calls: { "call_1" => stub_tool_call(name: "todo_write", arguments: '{"action":"add","title":"Write adapter tests"}') }),
      ResponseMessage.new(content: "todo added")
    ])
    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5,
      tools: [EchoTool.new],
      todos: true
    )
    adapter.start
    sid = adapter.create_session("/tmp")

    events, _queue, thread = run_turn(adapter, sid, "Add a todo", timeout: 15)
    thread.join(15)

    todo_event = events.find { |e| e[:type] == "todos.updated" }
    refute_nil todo_event, "expected todos.updated, got #{events.map { |e| e[:type] }}"
    assert_includes todo_event.dig(:payload, "todos").to_s, "Write adapter tests"
  ensure
    adapter&.stop
  end

  # ── Abort ──

  def test_abort_emits_turn_aborted
    build_chat_stub(sequence: [
      ResponseMessage.new(content: "", tool_calls: { "call_1" => stub_tool_call(name: "echo_approval") })
    ])
    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5,
      tools: [EchoApprovalTool.new],
      approval: :require
    )
    adapter.start
    sid = adapter.create_session("/tmp")

    events, queue, thread = run_turn(adapter, sid, "Echo", timeout: 15)
    wait_for(queue, "approval.required")

    adapter.abort(sid)
    thread.join(15)

    assert events.any? { |e| e[:type] == "turn.aborted" }
    refute events.any? { |e| e[:type] == "turn.completed" }
  ensure
    adapter&.stop
  end

  # ── Persistence ──

  def test_session_persists_across_turns
    chat = build_chat_stub(sequence: [
      ResponseMessage.new(content: "first reply"),
      ResponseMessage.new(content: "second reply")
    ])
    sid = @adapter.create_session("/tmp")

    events1, _q1, t1 = run_turn(@adapter, sid, "First question")
    t1.join(15)
    events2, _q2, t2 = run_turn(@adapter, sid, "Second question")
    t2.join(15)

    # Same underlying session: both turns' messages are in history.
    history = @adapter.session_history(sid)
    texts = history.map { |m| m[:text] }
    assert_includes texts, "First question"
    assert_includes texts, "Second question"

    # The conversation accumulated in the chat stub.
    user_msgs = chat.messages.select { |m| m.role == :user }
    assert_equal ["First question", "Second question"], user_msgs.map(&:content)
    assert events2.any? { |e| e[:type] == "turn.started" }
    assert events2.any? { |e| e[:type] == "turn.completed" }
  end

  def test_model_override_per_session
    build_chat_stub(sequence: [ResponseMessage.new(content: "ok")])
    sid = @adapter.create_session("/tmp", model: "claude-sonnet-4")
    snapshot = @adapter.resume_session(sid)
    assert_equal "claude-sonnet-4", snapshot["model"]
  end

  # ── Failure handling ──

  def test_failed_turn_emits_turn_failed
    chat = build_chat_stub(sequence: [ResponseMessage.new(content: "boom")])
    chat.define_singleton_method(:ask) do |*|
      raise "provider exploded"
    end
    sid = @adapter.create_session("/tmp")

    events, _queue, thread = run_turn(@adapter, sid, "Break it")
    thread.join(15)

    failed = events.find { |e| e[:type] == "turn.failed" }
    refute_nil failed, "expected turn.failed, got #{events.map { |e| e[:type] }}"
    assert_includes failed.dig(:payload, "error", "message"), "provider exploded"
  end
end
