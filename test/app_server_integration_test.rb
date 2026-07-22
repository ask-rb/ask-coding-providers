# frozen_string_literal: true

# Real app-server integration tests.
# These start a real `zcode app-server` process and verify actual RPC behavior.
#
# Run: INTEGRATION=1 bundle exec ruby -Itest test/app_server_integration_test.rb
#
# These tests are skipped by default because they require:
#   1. `zcode` CLI installed (or ZCODE_CLI_PATH set)
#   2. A valid config at ~/.zcode/cli/config.json
#   3. An actual session to test against (optional)

require_relative "test_helper"
require "json"
require "fileutils"

class AppServerIntegrationTest < Minitest::Test
  INTEGRATION_ENABLED = ENV["INTEGRATION"] == "1"

  def setup
    skip "Set INTEGRATION=1 to run app-server integration tests" unless INTEGRATION_ENABLED

    @client = Ask::CodingProviders::ZCode::AppServerClient.new(
      cwd: Dir.pwd,
      request_timeout: 30
    )
    @client.start
    sleep 1  # Give it a moment to start
  end

  def teardown
    return unless INTEGRATION_ENABLED
    @client&.stop
  end

  def test_app_server_starts
    assert @client.running?, "App-server should be running"
  end

  def test_create_session_works
    sid = @client.create_session(Dir.pwd)
    assert sid, "Should return a session ID"
    assert_match(/^sess_/, sid, "Session ID should start with sess_")
  end

  def test_create_and_send_message
    sid = @client.create_session(Dir.pwd)
    result = @client.send_message(sid, "Hello from integration test")
    assert result.is_a?(Hash), "send_message should return a Hash"
  end

  def test_list_sessions_returns_array
    sessions = @client.list_sessions(limit: 5)
    assert_kind_of Array, sessions
  end

  def test_resume_nonexistent_session_raises
    assert_raises(Ask::CodingProviders::ZCode::Error) do
      @client.resume_session("sess_nonexistent")
    end
  end

  def test_read_workspace_state
    result = @client.read_workspace_state(Dir.pwd)
    assert result.is_a?(Hash), "Should return a Hash"
    refute_empty result, "Workspace state should not be empty"
  end

  def test_subscribe_returns_event_seq
    sid = @client.create_session(Dir.pwd)
    result = @client.subscribe(sid)
    assert result.is_a?(Hash)
    seq = result["eventSeq"] || result[:eventSeq]
    assert seq.is_a?(Integer), "Should have eventSeq"
  end

  def test_create_session_twice_returns_different_ids
    sid1 = @client.create_session(Dir.pwd)
    sid2 = @client.create_session(Dir.pwd)
    refute_equal sid1, sid2, "Two sessions should have different IDs"
  end

  def test_create_session_with_mode
    sid = @client.create_session(Dir.pwd, mode: "build")
    assert sid
    assert_match(/^sess_/, sid)
  end

  def test_send_message_to_nonexistent_session_raises
    assert_raises(Ask::CodingProviders::ZCode::Error) do
      @client.send_message("sess_nonexistent", "hello")
    end
  end

  # ── Model availability tests ──

  def test_workspace_state_shows_available_models
    result = @client.read_workspace_state(Dir.pwd)
    model = result.dig("settings", "model")
    skip "No model info in workspace state" unless model

    current = model["current"] || {}
    available = model["available"] || []
    refute_empty available, "Should have at least one available model"

    puts "\n  Current: #{current["modelId"]} (#{current["providerId"]})"
    puts "  Available: #{available.map { |a| "#{a.dig("ref", "modelId")} (#{a.dig("ref", "providerId")})" }.join(", ")}"
  end

  def test_create_session_with_model_from_workspace
    # Get the current model from workspace state and create a session with it
    state = @client.read_workspace_state(Dir.pwd)
    model = state.dig("settings", "model")
    skip "No model info" unless model

    current = model["current"] || {}
    available = model["available"] || []
    skip "No available models" if available.empty?

    sid = @client.create_session(Dir.pwd)
    result = @client.send_message(sid, "Hello")
    assert result.is_a?(Hash), "send_message should work with current model"
  end

  # ── subscribe + events flow ──

  def test_subscribe_and_get_events
    sid = @client.create_session(Dir.pwd)

    # Subscribe first
    sub = @client.subscribe(sid)
    seq = sub["eventSeq"] || sub[:eventSeq] || 0

    # Send a message (this generates events)
    @client.send_message(sid, "Hello")

    # Try to get events
    events = @client.get_events(sid, after_seq: seq)
    assert_kind_of Array, events["events"] || events[:events] || events
  end
end
