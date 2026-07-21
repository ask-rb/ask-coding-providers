# frozen_string_literal: true

require_relative "test_helper"

class CodingAdapterTest < Minitest::Test
  class TestAdapter < Ask::CodingProviders::Adapter
  end

  def setup
    @adapter = TestAdapter.new
  end

  def test_create_session_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.create_session("/tmp") }
  end

  def test_resume_session_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.resume_session("sess_123") }
  end

  def test_list_sessions_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.list_sessions }
  end

  def test_subscribe_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.subscribe("sess_123") }
  end

  def test_send_message_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.send_message("sess_123", "hello") }
  end

  def test_send_and_stream_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.send_and_stream("sess_123", "hello") }
  end

  def test_get_events_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.get_events("sess_123", after_seq: 0) }
  end

  def test_respond_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.respond(1, {}) }
  end

  def test_start_does_not_raise
    @adapter.start
  end

  def test_stop_does_not_raise
    @adapter.stop
  end

  def test_running_returns_true_by_default
    assert @adapter.running?
  end
end
