# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"

class ZCodeTest < Minitest::Test
  def setup
    @adapter = Ask::CodingProviders::ZCode::Adapter.new(
      cwd: Dir.pwd, request_timeout: 0.1
    )
  end

  def teardown
    @adapter&.stop
  end

  def test_adapter_implements_interface
    assert_kind_of Ask::CodingProviders::Adapter, @adapter
  end

  def test_responds_to_all_interface_methods
    %i[create_session resume_session list_sessions subscribe
       send_message send_and_stream get_events respond
       start stop running?].each do |m|
      assert_respond_to @adapter, m
    end
  end

  def test_running_false_by_default
    refute @adapter.running?
  end

  def test_list_sessions_returns_empty_without_app_server
    assert_equal [], @adapter.list_sessions
  end

  def test_get_events_returns_empty_without_app_server
    assert_equal({}, @adapter.get_events("sess_1", after_seq: 0))
  end

  def test_respond_does_not_raise_without_app_server
    @adapter.respond(1, {})
  end

  def test_create_session_returns_fallback_id
    sid = @adapter.create_session("/tmp")
    assert_match(/^fallback_/, sid)
  end

  def test_send_and_stream_raises_without_app_server
    assert_raises(RuntimeError) do
      @adapter.send_and_stream("sess_1", "hello") { |e| }
    end
  end

  def test_send_message_uses_fallback_without_server
    result = @adapter.send_message("sess_1", "hello")
    # Should not raise, fallback just returns nil if not started
  end

  def test_subscribe_returns_empty_without_server
    assert_equal({}, @adapter.subscribe("sess_1"))
  end

  def test_resume_session_returns_empty_without_server
    assert_equal({}, @adapter.resume_session("sess_1"))
  end

  def test_stop_does_not_raise_when_not_started
    @adapter.stop
  end

  # AppServerClient tests
  def test_app_server_client_initializes
    client = Ask::CodingProviders::ZCode::AppServerClient.new(
      cwd: Dir.pwd, cli_path: "/usr/bin/true", request_timeout: 0.1
    )
    assert_equal "/usr/bin/true", client.cli_path
  end

  def test_cli_path_resolution_from_env
    ENV["ZCODE_CLI_PATH"] = "/usr/bin/true"
    begin
      path = Ask::CodingProviders::ZCode::AppServerClient.resolve_cli_path
      assert_equal "/usr/bin/true", path
    ensure
      ENV.delete("ZCODE_CLI_PATH")
    end
  end

  def test_request_without_start_raises
    client = Ask::CodingProviders::ZCode::AppServerClient.new(
      cwd: Dir.pwd, cli_path: "/usr/bin/true", request_timeout: 0.1
    )
    assert_raises(Ask::CodingProviders::ZCode::AppServerUnavailable) do
      client.request("test", {})
    end
  end

  def test_send_message_without_start_raises
    client = Ask::CodingProviders::ZCode::AppServerClient.new(
      cwd: Dir.pwd, cli_path: "/usr/bin/true", request_timeout: 0.1
    )
    assert_raises(Ask::CodingProviders::ZCode::AppServerUnavailable) do
      client.send_message("sess_123", "hello")
    end
  end

  def test_create_session_without_start_raises
    client = Ask::CodingProviders::ZCode::AppServerClient.new(
      cwd: Dir.pwd, cli_path: "/usr/bin/true", request_timeout: 0.1
    )
    assert_raises(Ask::CodingProviders::ZCode::AppServerUnavailable) do
      client.create_session("/tmp")
    end
  end

  def test_respond_raises_without_start
    client = Ask::CodingProviders::ZCode::AppServerClient.new(
      cwd: Dir.pwd, cli_path: "/usr/bin/true", request_timeout: 0.1
    )
    assert_raises(Ask::CodingProviders::ZCode::AppServerUnavailable) do
      client.respond(1, {})
    end
  end

  def test_on_notification_registers_handler
    client = Ask::CodingProviders::ZCode::AppServerClient.new(
      cwd: Dir.pwd, cli_path: "/usr/bin/true", request_timeout: 0.1
    )
    called = false
    client.on_notification { |m, p, r| called = true }
    assert client.send(:instance_variable_get, :@event_handlers).length >= 1
  end

  def test_dispatch_notification_calls_handlers
    client = Ask::CodingProviders::ZCode::AppServerClient.new(
      cwd: Dir.pwd, cli_path: "/usr/bin/true", request_timeout: 0.1
    )
    received = []
    client.on_notification { |m, p, r| received << [m, p, r] }
    client.send(:dispatch_notification, "test.method", { "key" => "val" }, 42)
    assert_equal 1, received.length
    assert_equal "test.method", received[0][0]
    assert_equal "val", received[0][1]["key"]
    assert_equal 42, received[0][2]
  end

  def test_dispatch_notification_handles_handler_errors
    client = Ask::CodingProviders::ZCode::AppServerClient.new(
      cwd: Dir.pwd, cli_path: "/usr/bin/true", request_timeout: 0.1
    )
    client.on_notification { |m, p, r| raise "boom" }
    client.on_notification { |m, p, r| @called = true }
    client.send(:dispatch_notification, "test", {}, nil)
    assert @called
  end

	  def test_make_error_maps_codes
	    client = Ask::CodingProviders::ZCode::AppServerClient.new(
	      cwd: Dir.pwd, cli_path: "/usr/bin/true", request_timeout: 0.1
	    )
	    err = client.send(:make_error, { "code" => -32004, "message" => "Session closed" })
	    assert_kind_of Ask::CodingProviders::ZCode::SessionUnavailable, err

	    err = client.send(:make_error, { "code" => -32010, "message" => "Already running" })
	    assert_kind_of Ask::CodingProviders::ZCode::PromptAlreadyRunning, err

	    err = client.send(:make_error, { "code" => -32031, "message" => "历史任务使用的模型已不可用" })
	    assert_kind_of Ask::CodingProviders::ZCode::Error, err
	    assert_includes err.message, "-32031"

	    err = client.send(:make_error, { "code" => -1, "message" => "Generic" })
	    assert_kind_of Ask::CodingProviders::ZCode::Error, err
	  end

  def test_create_session_parses_result
    # Test the high-level API by stubbing the low-level request method
    client = client_with_mocked_request
    client.stubs(:request).with("session/create", anything)
      .returns({ "session" => { "sessionId" => "sess_test_123" } })

    sid = client.create_session("/tmp")
    assert_equal "sess_test_123", sid
  end

  def test_create_session_raises_without_session_id
    client = client_with_mocked_request
    client.stubs(:request).with("session/create", anything)
      .returns({ "session" => {} })

    assert_raises(Ask::CodingProviders::ZCode::Error) do
      client.create_session("/tmp")
    end
  end

  def test_list_sessions_parses_result
    client = client_with_mocked_request
    client.stubs(:request).returns({ "sessions" => [{ "sessionId" => "sess_1" }, { "sessionId" => "sess_2" }] })

    sessions = client.list_sessions
    assert_equal 2, sessions.length
  end

  def test_get_events_passes_limit
    client = client_with_mocked_request
    client.expects(:request).with("session/events", { sessionId: "sess_1", afterSeq: 5, limit: 10 })
      .returns({ "events" => [] })

    client.get_events("sess_1", after_seq: 5, limit: 10)
  end

  def test_get_events_without_limit
    client = client_with_mocked_request
    client.expects(:request).with("session/events", { sessionId: "sess_1", afterSeq: 0 })
      .returns({ "events" => [] })

    client.get_events("sess_1", after_seq: 0)
  end

  # Helper to create a client that appears running with a stubbed request method
  def client_with_mocked_request
    client = Ask::CodingProviders::ZCode::AppServerClient.new(
      cwd: Dir.pwd, cli_path: "/usr/bin/true", request_timeout: 0.1
    )
    client.stubs(:running?).returns(true)
    # Bypass ensure_running by stubbing it
    client.define_singleton_method(:ensure_running) { }
    client.instance_variable_set(:@started, true)
    client.instance_variable_set(:@wait_thr, Object.new)
    client
  end

  # Client (--prompt mode) tests
  def test_client_initializes
    client = Ask::CodingProviders::ZCode::Client.new(
      working_dir: Dir.pwd, cli_path: "/usr/bin/true"
    )
    assert_kind_of Ask::CodingProviders::ZCode::Client, client
  end

  def test_client_parse_output_with_valid_json
    client = Ask::CodingProviders::ZCode::Client.new(
      working_dir: Dir.pwd, cli_path: "/usr/bin/true"
    )
    result = client.send(:parse_output,
      OpenStruct.new(exitstatus: 0),
      '{"response":"Hello","sessionId":"sess_123","usage":{"totalTokens":50}}',
      ""
    )
    assert_kind_of Ask::CodingProviders::ZCode::Client::Result, result
    assert_equal "Hello", result.response
    assert_equal "sess_123", result.session_id
    assert_equal 50, result.total_tokens
  end

  def test_client_parse_output_with_invalid_json_raises
    client = Ask::CodingProviders::ZCode::Client.new(
      working_dir: Dir.pwd, cli_path: "/usr/bin/true"
    )
    assert_raises(Ask::CodingProviders::ZCode::CLIError) do
      client.send(:parse_output, OpenStruct.new(exitstatus: 1), "", "Error: failed")
    end
  end

  def test_client_result_error_flag
    result = Ask::CodingProviders::ZCode::Client::Result.new(
      response: "Ok", session_id: "sess_1", usage: {}, projection: {}, raw: { "isError" => true }
    )
    assert result.error?
  end

  def test_client_result_non_error_by_default
    result = Ask::CodingProviders::ZCode::Client::Result.new(
      response: "Ok", session_id: "sess_1", usage: {}, projection: {}, raw: {}
    )
    refute result.error?
  end

  def test_client_result_total_tokens_defaults_to_zero
    result = Ask::CodingProviders::ZCode::Client::Result.new(
      response: "Ok", session_id: "sess_1", usage: nil, projection: {}, raw: {}
    )
    assert_equal 0, result.total_tokens
  end

  def test_adapter_start_stop_cycle
    adapter = Ask::CodingProviders::ZCode::Adapter.new(
      cwd: Dir.pwd, request_timeout: 0.1
    )

    # Without app-server available, start attempts to spawn but fails silently
    adapter.start
    # After stop, should not be running
    adapter.stop
    # Can call stop multiple times
    adapter.stop
  end

  def test_adapter_with_app_server_disabled
    ENV["ZCODE_USE_APP_SERVER"] = "0"
    begin
      adapter = Ask::CodingProviders::ZCode::Adapter.new(cwd: Dir.pwd)
      adapter.start
      assert adapter.running?
      adapter.stop
    ensure
      ENV["ZCODE_USE_APP_SERVER"] = "1"
    end
  end
end
