# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"

# Approval scopes on the AskAgent adapter: scope pass-through to
# Ask::Permissions::ApprovalQueue, session grants observed through the
# actual adapter session, the default :once staying one-shot, and explicit
# rejection of :project (this adapter never injects project grants).
class ApprovalScopeTest < Minitest::Test
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
  end

  def teardown
    @adapter&.stop
  end

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
      unless _message.to_s.empty?
        messages << Ask::Message.new(role: :user, content: _message)
      end
      response = sequence.shift || sequence.last
      if block && response
        chunks = []
        chunks << StreamChunk.new(content: nil, thinking: response.thinking) unless response.thinking.to_s.empty?
        chunks << StreamChunk.new(content: response.content, thinking: nil) if response.content.to_s.length > 0
        chunks << StreamChunk.new(content: "", thinking: nil, tool_calls: response.tool_calls) unless response.tool_calls.empty?
        chunks.each { |c| block.call(c) }
      end
      response
    end
    Ask::Agent::Chat.stubs(:new).returns(stub)
    stub
  end

  def tool_call_message(id, text)
    ResponseMessage.new(
      content: "",
      tool_calls: { id => Ask::Agent::ToolCallInfo.new(id: id, name: "echo_approval", arguments: %({"text":"#{text}"})) }
    )
  end

  # Two identical approval-gated turns: each starts with the same tool
  # call (same name + args) and ends with its own closing reply.
  def two_identical_tool_turns
    [
      tool_call_message("call_1", "hi"),
      ResponseMessage.new(content: "first done"),
      tool_call_message("call_2", "hi"),
      ResponseMessage.new(content: "second done")
    ]
  end

  def build_approval_adapter(approval: :require)
    @adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 10,
      tools: [EchoApprovalTool.new], approval: approval
    )
    @adapter.start
    @adapter
  end

  def run_turn(adapter, sid, prompt, timeout: 15)
    events = []
    queue = Queue.new
    thread = Thread.new do
      begin
        adapter.send_and_stream(sid, prompt, turn_timeout: timeout) do |ev|
          events << ev
          queue << ev
        end
      rescue => e
        queue << { type: "THREAD_ERROR", error: "#{e.class}: #{e.message}" }
      end
    end
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

  # ── Default scope (:once) stays one-shot ──

  def test_approve_action_default_scope_is_one_shot
    build_chat_stub(sequence: two_identical_tool_turns)
    adapter = build_approval_adapter
    sid = adapter.create_session("/tmp")

    events1, queue1, thread1 = run_turn(adapter, sid, "Echo 1")
    required1 = wait_for(queue1, "approval.required")
    adapter.approve_action(sid, required1.dig(:payload, "actionId"))
    thread1.join(15)
    assert events1.any? { |e| e[:type] == "turn.completed" }
    assert_empty adapter.pending_approvals(sid)

    # Same tool + args again: the default :once approval must not persist,
    # so the action queues for review a second time.
    events2, queue2, thread2 = run_turn(adapter, sid, "Echo 2", timeout: 5)
    required2 = wait_for(queue2, "approval.required", timeout: 5)
    assert_equal "echo_approval", required2.dig(:payload, "toolName")
    adapter.approve_action(sid, required2.dig(:payload, "actionId"))
    thread2.join(10)
    assert events2.any? { |e| e[:type] == "turn.completed" }
  end

  # ── Session scope grants through the actual adapter session ──

  def test_approve_action_session_scope_grants_session
    build_chat_stub(sequence: two_identical_tool_turns)
    adapter = build_approval_adapter
    sid = adapter.create_session("/tmp")

    events1, queue1, thread1 = run_turn(adapter, sid, "Echo 1")
    required = wait_for(queue1, "approval.required")
    adapter.approve_action(sid, required.dig(:payload, "actionId"), scope: :session)
    thread1.join(15)
    assert events1.any? { |e| e[:type] == "turn.completed" }
    assert_empty adapter.pending_approvals(sid)

    # The session grant auto-allows the repeated action: no new approval
    # gate, the tool runs, and the turn completes.
    events2, _queue2, thread2 = run_turn(adapter, sid, "Echo 2", timeout: 5)
    thread2.join(10)
    refute thread2.alive?, "granted turn should finish without human approval"
    refute events2.any? { |e| e[:type] == "approval.required" },
           "session grant should auto-approve the repeated action, got: #{events2.map { |e| e[:type] }}"
    results = events2.select { |e| e[:type] == "tool.result" }
    assert_equal 1, results.size
    assert_equal false, results.first.dig(:payload, "isError")
    completed = events2.find { |e| e[:type] == "turn.completed" }
    refute_nil completed, "expected turn.completed, got #{events2.map { |e| e[:type] }}"
    assert_equal "second done", completed.dig(:payload, "response")
  end

  def test_approve_all_session_scope_grants_session
    build_chat_stub(sequence: two_identical_tool_turns)
    adapter = build_approval_adapter
    sid = adapter.create_session("/tmp")

    events1, queue1, thread1 = run_turn(adapter, sid, "Echo 1")
    wait_for(queue1, "approval.required")
    adapter.approve_all(sid, scope: :session)
    thread1.join(15)
    assert events1.any? { |e| e[:type] == "turn.completed" }

    events2, _queue2, thread2 = run_turn(adapter, sid, "Echo 2", timeout: 5)
    thread2.join(10)
    refute thread2.alive?, "granted turn should finish without human approval"
    refute events2.any? { |e| e[:type] == "approval.required" },
           "session grant from approve_all should auto-approve, got: #{events2.map { |e| e[:type] }}"
    assert events2.any? { |e| e[:type] == "tool.result" }
    assert events2.any? { |e| e[:type] == "turn.completed" }
  end

  # ── Scope pass-through to the queue ──

  def test_approve_action_passes_scope_through_to_queue
    adapter = build_approval_adapter
    sid = adapter.create_session("/tmp")
    received = nil
    fake_queue = Object.new
    fake_queue.define_singleton_method(:approve) do |action_id, scope:|
      received = { action_id: action_id, scope: scope }
      []
    end
    adapter.define_singleton_method(:approval_queue) { |_sid| fake_queue }

    assert_equal [], adapter.approve_action(sid, 7, scope: :session)
    assert_equal({ action_id: 7, scope: :session }, received)

    adapter.approve_action(sid, 8)
    assert_equal({ action_id: 8, scope: :once }, received)
  end

  def test_approve_all_passes_scope_through_to_queue
    adapter = build_approval_adapter
    sid = adapter.create_session("/tmp")
    received = nil
    fake_queue = Object.new
    fake_queue.define_singleton_method(:approve_all) do |scope:|
      received = scope
      []
    end
    adapter.define_singleton_method(:approval_queue) { |_sid| fake_queue }

    assert_equal [], adapter.approve_all(sid, scope: :session)
    assert_equal :session, received

    adapter.approve_all(sid)
    assert_equal :once, received
  end

  # ── :project and unknown scopes rejected ──

  def test_project_scope_rejected_by_approve_action
    adapter = build_approval_adapter
    sid = adapter.create_session("/tmp")

    error = assert_raises(ArgumentError) do
      adapter.approve_action(sid, 1, scope: :project)
    end
    assert_includes error.message, ":project"
    assert_includes error.message, "not supported"
  end

  def test_project_scope_rejected_by_approve_all
    adapter = build_approval_adapter
    sid = adapter.create_session("/tmp")

    error = assert_raises(ArgumentError) do
      adapter.approve_all(sid, scope: :project)
    end
    assert_includes error.message, ":project"
    assert_includes error.message, "not supported"
  end

  def test_project_scope_rejected_even_without_a_queue
    # No queue exists (approval off, session never run): :project must
    # still raise rather than silently returning [] as a no-op.
    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", approval: :off
    )
    adapter.start
    sid = adapter.create_session("/tmp")

    assert_raises(ArgumentError) { adapter.approve_action(sid, 1, scope: :project) }
    assert_raises(ArgumentError) { adapter.approve_all(sid, scope: :project) }

    # Valid scopes keep the existing no-queue behavior.
    assert_equal [], adapter.approve_action(sid, 1, scope: :session)
    assert_equal [], adapter.approve_all(sid, scope: :once)
  end

  def test_unknown_scope_rejected
    adapter = build_approval_adapter
    sid = adapter.create_session("/tmp")

    assert_raises(ArgumentError) { adapter.approve_action(sid, 1, scope: :workspace) }
    assert_raises(ArgumentError) { adapter.approve_all(sid, scope: :workspace) }
  end
end
