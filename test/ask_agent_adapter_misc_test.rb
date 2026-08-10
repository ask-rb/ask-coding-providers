# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"

# Covers the adapter's remaining branches: approval :auto/:off modes,
# session listing/subscription, queue controls without a queue, timeouts,
# and result serialization.
class AskAgentAdapterMiscTest < Minitest::Test
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

  FakeProvider = Class.new do
    def self.compat_config = {}
    def initialize(api_key:); end
  end

  class EchoTool < Ask::Tool
    description "Echo the given text back"
    param :text, type: :string, required: true

    def execute(text:)
      Ask::Result.ok(data: { echoed: text })
    end
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

  def build_adapter(**opts)
    @adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5, **opts
    )
    @adapter.start
    @adapter
  end

  # ── Approval modes ──

  def test_auto_mode_keeps_queue_but_never_blocks
    build_chat_stub(sequence: [ResponseMessage.new(content: "done")])
    adapter = build_adapter(approval: :auto)
    sid = adapter.create_session("/tmp")

    events = []
    adapter.send_and_stream(sid, "hi") { |ev| events << ev }

    # Queue exists and is inspectable; nothing queued for a plain turn.
    assert events.any? { |e| e[:type] == "turn.completed" }
    assert_equal [], adapter.pending_approvals(sid)
  end

  def test_off_mode_has_no_queue
    build_chat_stub(sequence: [ResponseMessage.new(content: "done")])
    adapter = build_adapter(approval: :off)
    sid = adapter.create_session("/tmp")

    adapter.send_and_stream(sid, "hi") { |_| }
    session = adapter.instance_variable_get(:@sessions)[sid][:session]
    assert_nil session.approval_queue
    assert_equal [], adapter.pending_approvals(sid)
    assert_equal [], adapter.approve_action(sid, 1)
  end

  def test_invalid_approval_mode_raises
    assert_raises(ArgumentError) do
      build_adapter(approval: :sometimes)
    end
  end

  # ── Session listing / subscription ──

  def test_list_sessions_filters_by_workspace
    build_chat_stub(sequence: [ResponseMessage.new(content: "ok")])
    adapter = build_adapter
    a = adapter.create_session("/proj/a")
    adapter.create_session("/proj/b")

    assert_equal ["/proj/a"], adapter.list_sessions(workspace_path: "/proj/a").map { |s| s[:workspace] }
    assert_equal 2, adapter.list_sessions.size
    assert_includes adapter.list_sessions.map { |s| s[:session_id] }, a
  end

  def test_subscribe_and_get_events
    adapter = build_adapter
    sid = adapter.create_session("/tmp")
    assert_equal({ "eventSeq" => 0 }, adapter.subscribe(sid))
    assert_equal({ "events" => [] }, adapter.get_events(sid, after_seq: 0))
    assert_nil adapter.respond("req-1", {})
  end

  def test_session_directory_and_resume
    adapter = build_adapter
    sid = adapter.create_session("/proj")
    assert_equal "/proj", adapter.session_directory(sid)
    assert_nil adapter.session_directory("nope")
    assert_equal({}, adapter.resume_session("nope"))
  end

  def test_send_message_returns_response_hash
    build_chat_stub(sequence: [ResponseMessage.new(content: "the answer")])
    adapter = build_adapter
    sid = adapter.create_session("/tmp")
    result = adapter.send_message(sid, "question")
    assert_equal "the answer", result["response"]
  end

  # ── Turn timeout ──

  def test_turn_timeout_aborts_when_approval_never_resolves
    # The tool queues for approval and nobody ever approves: the turn waits
    # until turn_timeout, aborts, and emits turn.failed.
    build_chat_stub(sequence: [
      ResponseMessage.new(content: "", tool_calls: { "call_1" => Ask::Agent::ToolCallInfo.new(id: "call_1", name: "echo", arguments: '{"text":"hi"}') }),
      ResponseMessage.new(content: "done")
    ])
    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5,
      tools: [EchoTool.new],
      approval: :require, approval_required: ["echo"]
    )
    adapter.start

    sid = adapter.create_session("/tmp")
    events = []
    started = Time.now
    adapter.send_and_stream(sid, "hi", turn_timeout: 1) { |ev| events << ev }
    elapsed = Time.now - started

    assert_operator elapsed, :>=, 1, "should wait at least the timeout"
    assert_operator elapsed, :<, 10, "should not wait forever"
    failed = events.find { |e| e[:type] == "turn.failed" }
    refute_nil failed, "expected turn.failed, got #{events.map { |e| e[:type] }}"
    assert_includes failed.dig(:payload, "error", "message"), "timed out after 1s"
  ensure
    adapter&.stop
  end

  # ── Result serialization ──

  def test_tool_output_serializes_result_types
    adapter = build_adapter
    # Private helper: exercise the different result shapes.
    send = adapter.method(:tool_output)
    assert_equal "", send.call(nil)
    assert_equal "plain", send.call("plain")
    assert_equal "data!", send.call(Ask::Result.ok(data: "data!"))
    assert_equal "nope", send.call(Ask::Result.error(message: "nope"))
    assert_equal "45", send.call(45)
  end
end
