# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class ACPAdapterTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("acp_adapter_test")
    @agent_script = File.join(@tmpdir, "mock_acp_agent.rb")
    File.write(@agent_script, MOCK_AGENT_SCRIPT)
    File.chmod(0o755, @agent_script)
    @adapter = Ask::CodingProviders::ACP::Adapter.new(
      command: ["ruby", @agent_script],
      cwd: @tmpdir,
      request_timeout: 5
    )
  end

  def teardown
    @adapter&.stop
    FileUtils.remove_entry(@tmpdir)
  end

  def test_adapter_implements_interface
    assert_kind_of Ask::CodingProviders::Adapter, @adapter
  end

  def test_responds_to_all_interface_methods
    methods = %i[create_session resume_session subscribe
                 send_message send_and_stream get_events respond
                 start stop running? get_workspace_state
                 handle_session_error list_projects find_sessions
                 find_recent_session session_directory session_history
                 recent_sessions]
    methods.each do |m|
      assert_respond_to @adapter, m, "Adapter should respond to #{m}"
    end
  end

  def test_not_running_by_default
    refute @adapter.running?
  end

  def test_start_stop_cycle
    @adapter.start
    assert @adapter.running?
    @adapter.stop
    refute @adapter.running?
  end

  def test_create_session_returns_id
    @adapter.start
    sid = @adapter.create_session(@tmpdir)
    assert sid, "Should return a session ID"
    refute_empty sid, "Session ID should not be empty"
  end

  def test_send_message_returns_result
    @adapter.start
    sid = @adapter.create_session(@tmpdir)
    result = @adapter.send_message(sid, "Hello")
    assert result.is_a?(Hash), "send_message should return a Hash"
  end

  def test_send_and_stream_receives_events
    @adapter.start
    sid = @adapter.create_session(@tmpdir)
    events = []
    @adapter.send_and_stream(sid, "Hello") { |ev| events << ev }
    assert_operator events.length, :>=, 1
    types = events.map { |e| e[:type] }
    assert_includes types, "turn.started"
  end

  def test_resume_returns_hash
    @adapter.start
    result = @adapter.resume_session("sess_test")
    assert_kind_of Hash, result
  end

  def test_get_events_returns_empty
    @adapter.start
    assert_equal({}, @adapter.get_events("sess_1", after_seq: 0))
  end

  def test_subscribe_returns_event_seq
    @adapter.start
    result = @adapter.subscribe("sess_1")
    assert_equal 0, result["eventSeq"]
  end

  def test_get_workspace_state_returns_empty
    @adapter.start
    assert_equal({}, @adapter.get_workspace_state("/tmp"))
  end

  def test_from_config_parses_command_string
    ENV["ACP_COMMAND"] = "codex acp"
    begin
      adapter = Ask::CodingProviders::ACP::Adapter.from_config
      assert_kind_of Ask::CodingProviders::ACP::Adapter, adapter
    ensure
      ENV.delete("ACP_COMMAND")
    end
  end

  def test_from_config_raises_without_command
    ENV.delete("ACP_COMMAND")
    assert_raises(Ask::CodingProviders::ConfigurationError) do
      Ask::CodingProviders::ACP::Adapter.from_config
    end
  end

  def test_adapter_registered_in_registry
    klass = Ask::CodingProviders.resolve_adapter("acp")
    assert_equal Ask::CodingProviders::ACP::Adapter, klass
  end

  # Mock ACP agent script
  MOCK_AGENT_SCRIPT = <<~'RUBY'
    #!/usr/bin/env ruby
    $stdin.sync = true; $stdout.sync = true
    require "json"
    $stdin.each_line do |line|
      msg = JSON.parse(line) rescue next
      id = msg["id"]; method = msg["method"]; params = msg["params"] || {}
      case method
      when "initialize"
        r = { jsonrpc: "2.0", id: id, result: { protocolVersion: 1, capabilities: {}, serverInfo: { name: "mock", version: "1" } } }
        $stdout.puts(JSON.generate(r)); $stdout.flush
      when "session/new"
        r = { jsonrpc: "2.0", id: id, result: { session: { id: "sess_#{Time.now.to_i}", status: "running" } } }
        $stdout.puts(JSON.generate(r)); $stdout.flush
      when "session/resume"
        r = { jsonrpc: "2.0", id: id, result: { session: { id: params["sessionId"], status: "running" } } }
        $stdout.puts(JSON.generate(r)); $stdout.flush
      when "session/prompt"
        $stdout.puts(JSON.generate({ jsonrpc: "2.0", method: "text", params: { sessionId: params["sessionId"], content: "Hello!" } }))
        $stdout.flush
        $stdout.puts(JSON.generate({ jsonrpc: "2.0", method: "turn_complete", params: { sessionId: params["sessionId"] } }))
        $stdout.flush
        r = { jsonrpc: "2.0", id: id, result: { status: "completed" } }
        $stdout.puts(JSON.generate(r)); $stdout.flush
      else
        r = { jsonrpc: "2.0", id: id, result: {} }
        $stdout.puts(JSON.generate(r)); $stdout.flush
      end
    end
  RUBY
end
