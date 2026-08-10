# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "ostruct"

# Tests for declarative agent sessions (ask-agent convention: an
# agents/<name>/ directory with agent.rb + instructions.md in the
# workspace). Discovery is cwd-based AND cached module-wide, so each test
# chdirs into its workspace and forces re-discovery — exactly what the
# harness does per turn.
class AskAgentDeclarativeTest < Minitest::Test
  def setup
    @workspace = Dir.mktmpdir("ach-agents")
    @original_dir = Dir.pwd
  end

  def teardown
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(@workspace)
  end

  def write_agent(name, model: "gpt-4o", instructions: "You are the #{name} agent.\n", tools: [])
    dir = File.join(@workspace, "agents", name)
    FileUtils.mkdir_p(dir)
    tools_code = tools.empty? ? "" : "tools #{tools.inspect}\n"
    File.write(File.join(dir, "agent.rb"), <<~RUBY)
      module #{name.split("_").map(&:capitalize).join}
        class Agent < Ask::Agent::Definition
          model "#{model}"
          #{tools_code}
        end
      end
    RUBY
    File.write(File.join(dir, "instructions.md"), instructions)
    dir
  end

  # Discovery is cwd-based and cached module-wide: chdir into the
  # workspace and force re-discovery before building sessions.
  def in_workspace
    Dir.chdir(@workspace)
    Ask::Agent.rediscover!
    yield
  ensure
    Dir.chdir(@original_dir)
  end

  def build_chat_stub(sequence: [])
    stub = Object.new
    stub.define_singleton_method(:model) { "gpt-4o" }
    stub.define_singleton_method(:model_id) { "gpt-4o" }
    stub.define_singleton_method(:messages) { [] }
    stub.define_singleton_method(:with_instructions) { |_| stub }
    stub.define_singleton_method(:reset_messages!) {}
    stub.define_singleton_method(:add_message) { |**| }
    stub.define_singleton_method(:ask) do |_message, attachments: nil, &block|
      response = sequence.shift || sequence.last
      if block && response
        block.call(OpenStruct.new(content: response[:content], thinking: nil, tool_calls: {}))
      end
      OpenStruct.new(content: response[:content] || "", tool_calls: {}, tool_results: {}, thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil)
    end
    Ask::Agent::Chat.stubs(:new).returns(stub)
    stub
  end

  def build_adapter(**opts)
    adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash", provider: "opencode_go", max_turns: 5, **opts
    )
    adapter.start
    adapter
  end

  def test_agent_session_streams_and_completes
    write_agent("helper")
    build_chat_stub(sequence: [{ content: "helper reply" }])

    adapter = build_adapter
    events = []
    in_workspace do
      sid = adapter.create_session(@workspace, agent: "helper")
      adapter.send_and_stream(sid, "hi") { |ev| events << ev }
    end

    assert events.any? { |e| e[:type] == "turn.completed" }
    assert events.any? { |e| e[:type] == "model.streaming" }
  ensure
    adapter&.stop
  end

  def test_agent_instructions_become_the_system_prompt
    write_agent("helper", instructions: "You are the helper agent.\nAlways be brief.")
    stub = build_chat_stub(sequence: [{ content: "ok" }])
    applied = []
    stub.define_singleton_method(:with_instructions) { |p| applied << p; stub }

    adapter = build_adapter
    in_workspace do
      sid = adapter.create_session(@workspace, agent: "helper")
      adapter.send_and_stream(sid, "hi") { |_| }
    end

    assert_includes applied.join, "You are the helper agent."
    assert_includes applied.join, "Always be brief."
  ensure
    adapter&.stop
  end

  def test_unknown_agent_raises
    build_chat_stub(sequence: [{ content: "ok" }])
    adapter = build_adapter
    in_workspace do
      assert_raises(Ask::Agent::UnknownAgent) do
        adapter.send_and_stream(adapter.create_session(@workspace, agent: "nope"), "hi") { |_| }
      end
    end
  ensure
    adapter&.stop
  end
end
