# frozen_string_literal: true

require_relative "test_helper"

class EmittingApprovalQueueTest < Minitest::Test
  def test_subclasses_extracted_permissions_queue
    assert_operator Ask::CodingProviders::AskAgent::EmittingApprovalQueue, :<,
                    Ask::Permissions::ApprovalQueue
  end

  def test_submit_returns_sequential_ids_and_notifies_with_actions
    submitted = []
    statuses = []
    queue = Ask::CodingProviders::AskAgent::EmittingApprovalQueue.new(
      on_submit: ->(a) { submitted << a },
      on_status: ->(a) { statuses << a }
    )

    first = queue.submit(tool_call_id: "call_1", tool_name: "echo", args: { "text" => "a" })
    second = queue.submit(tool_call_id: "call_2", tool_name: "echo", args: { "text" => "b" })

    assert_kind_of Integer, first
    assert_equal first + 1, second
    assert_equal [first, second], submitted.map(&:id)
    assert_equal %w[call_1 call_2], submitted.map(&:tool_call_id)
    assert_equal %w[echo echo], submitted.map(&:tool_name)
  end
end
