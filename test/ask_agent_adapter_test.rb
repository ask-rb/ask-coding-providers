# frozen_string_literal: true

require_relative "test_helper"

class AskAgentAdapterTest < Minitest::Test
  def setup
    @adapter = Ask::CodingProviders::AskAgent::Adapter.new(
      model: "deepseek-v4-flash",
      provider: "opencode_go",
      max_turns: 2
    )
  end

  def teardown
    @adapter&.stop
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

  def test_create_session_returns_uuid
    @adapter.start
    sid = @adapter.create_session("/tmp")
    assert sid
    assert_match(/^sess_/, sid)
  end

  def test_send_without_start_raises
    assert_raises(RuntimeError) { @adapter.create_session("/tmp") }
  end

  # ── Real API tests (recorded with VCR) ──

  def setup_vcr_dummy_key
    # Provider needs an API key to initialize, even during VCR playback.
    # During recording, the real OPENCODE_API_KEY is used.
    ENV["OPENCODE_API_KEY"] ||= "dummy-for-vcr"
  end

  def test_send_and_stream_receives_response
    VCR.use_cassette("ask_agent_simple_chat") do
      setup_vcr_dummy_key
      @adapter.start
      sid = @adapter.create_session("/tmp")
      events = []
      @adapter.send_and_stream(sid, "Reply with just the word: hello") { |ev| events << ev }
      assert_operator events.length, :>=, 1
      completed = events.find { |e| e[:type] == "turn.completed" }
      refute_nil completed, "Should receive turn.completed"
      assert completed.dig(:payload, "response").to_s.length > 0
    end
  end

  def test_send_and_stream_yields_streaming_events
    VCR.use_cassette("ask_agent_streaming") do
      setup_vcr_dummy_key
      @adapter.start
      sid = @adapter.create_session("/tmp")
      types = []
      @adapter.send_and_stream(sid, "Count from 1 to 3") { |ev| types << ev[:type] }
      assert_includes types, "turn.started"
      assert_includes types, "turn.completed"
    end
  end

  def test_send_message_returns_response
    VCR.use_cassette("ask_agent_send_message") do
      setup_vcr_dummy_key
      @adapter.start
      sid = @adapter.create_session("/tmp")
      result = @adapter.send_message(sid, "Say hello")
      assert result.is_a?(Hash)
      assert result["response"].to_s.length > 0
    end
  end

  def test_handle_session_error_returns_nil
    # AskAgent adapter doesn't have ZCode-specific errors
    error = StandardError.new("Some random error")
    result = @adapter.handle_session_error("sess_1", error)
    assert_nil result
  end

  def test_list_projects_returns_nil
    assert_nil @adapter.list_projects
  end

  def test_session_history_returns_empty
    assert_equal [], @adapter.session_history("sess_1")
  end

  def test_get_workspace_state_returns_empty
    assert_equal({}, @adapter.get_workspace_state("/tmp"))
  end

  # ── Registry and from_config tests ──

  def test_adapter_registered_in_registry
    klass = Ask::CodingProviders.resolve_adapter("ask_agent")
    assert_equal Ask::CodingProviders::AskAgent::Adapter, klass
  end

  def test_from_config_uses_env_defaults
    adapter = Ask::CodingProviders::AskAgent::Adapter.from_config
    assert_kind_of Ask::CodingProviders::AskAgent::Adapter, adapter
    refute adapter.running?
  end

  def test_from_config_overrides_env
    adapter = Ask::CodingProviders::AskAgent::Adapter.from_config(
      model: "custom-model",
      llm_provider: "custom-provider",
      max_turns: 5
    )
    assert_kind_of Ask::CodingProviders::AskAgent::Adapter, adapter
  end

  def test_build_adapter_resolves_by_name
    adapter = Ask::CodingProviders.build_adapter("ask_agent")
    assert_kind_of Ask::CodingProviders::AskAgent::Adapter, adapter
  end

  def test_build_adapter_raises_for_unknown
    assert_raises(Ask::CodingProviders::ConfigurationError) do
      Ask::CodingProviders.build_adapter("nonexistent")
    end
  end

  def test_acp_adapter_registered
    klass = Ask::CodingProviders.resolve_adapter("acp")
    assert_equal Ask::CodingProviders::ACP::Adapter, klass
  end
end
