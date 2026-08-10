# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"

class DebugApprovalTest < Minitest::Test
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
    description "echo"
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

  def test_debug
    Ask::Provider.stubs(:resolve).with("opencode_go").returns(FakeProvider)
    sequence = [
      ResponseMessage.new(content: "", tool_calls: { "call_1" => Ask::Agent::ToolCallInfo.new(id: "call_1", name: "echo_approval", arguments: '{"text":"hi"}') }),
      ResponseMessage.new(content: "approved and done")
    ]
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
      r = sequence.shift || sequence.last
      if block && r
        chunks = []
        chunks << StreamChunk.new(content: nil, thinking: r.thinking) unless r.thinking.to_s.empty?
        chunks << StreamChunk.new(content: r.content, thinking: nil) if r.content.to_s.length > 0
        chunks << StreamChunk.new(content: "", thinking: nil, tool_calls: r.tool_calls) unless r.tool_calls.empty?
        chunks.each { |c| block.call(c) }
      end
      r
    end
    Ask::Agent::Chat.stubs(:new).returns(stub)

    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5,
      tools: [EchoApprovalTool.new], approval: :require
    )
    adapter.start
    sid = adapter.create_session("/tmp")
    events = []
    t = Thread.new do
      adapter.send_and_stream(sid, "Echo with approval", turn_timeout: 15) { |ev| events << ev }
    end
    deadline = Time.now + 10
    required = nil
    until required || Time.now > deadline
      sleep 0.05
      required = events.find { |e| e[:type] == "approval.required" }
    end
    puts "required: #{required && required[:type]}"
    begin
      result = adapter.approve_action(sid, required.dig(:payload, "actionId"))
      puts "approve result: #{result.inspect}"
    rescue => e
      puts "approve raised: #{e.class}: #{e.message}"
      puts e.backtrace.first(8)
    end
    t.join(15)
    events.each { |e| puts "#{e[:type]} #{e[:payload].reject { |k, _| k == 'sessionId' }.inspect[0..160]}" }
  end
end
