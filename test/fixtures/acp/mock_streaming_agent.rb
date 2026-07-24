#!/usr/bin/env ruby
# frozen_string_literal: true

$stdin.sync = true; $stdout.sync = true
require "json"

$stdin.each_line do |line|
  msg = JSON.parse(line) rescue next
  id = msg["id"]; method = msg["method"]; params = msg["params"] || {}
  case method
  when "initialize"
    $stdout.puts(JSON.generate({ jsonrpc: "2.0", id: id, result: { protocolVersion: 1, capabilities: {}, serverInfo: { name: "mock", version: "1" } } }))
  when "session/new"
    $stdout.puts(JSON.generate({ jsonrpc: "2.0", id: id, result: { session: { id: "sess_#{Time.now.to_i}", status: "running" } } }))
  when "session/resume"
    $stdout.puts(JSON.generate({ jsonrpc: "2.0", id: id, result: { session: { id: params["sessionId"], status: "running" } } }))
  when "session/prompt"
    sid = params["sessionId"]
    # Emit tool call
    $stdout.puts(JSON.generate({ jsonrpc: "2.0", method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "tool_call", kind: "read", content: [{ type: "text", text: "/tmp/file.rb" }] } } }))
    $stdout.flush
    $stdout.puts(JSON.generate({ jsonrpc: "2.0", method: "session/update", params: { sessionId: sid, update: { sessionUpdate: "tool_call_update", kind: "read", content: [{ type: "text", text: "def hello; end" }] } } }))
    $stdout.flush
    $stdout.puts(JSON.generate({ jsonrpc: "2.0", method: "text", params: { sessionId: sid, content: "Here's my analysis..." } }))
    $stdout.puts(JSON.generate({ jsonrpc: "2.0", method: "turn_complete", params: { sessionId: params["sessionId"] } }))
    $stdout.puts(JSON.generate({ jsonrpc: "2.0", id: id, result: { status: "completed" } }))
  else
    $stdout.puts(JSON.generate({ jsonrpc: "2.0", id: id, result: {} }))
  end
  $stdout.flush
end
