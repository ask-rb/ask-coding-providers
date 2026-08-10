# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "sqlite3"
require "json"
require "stringio"

# Tests for the external coding-agent adapters (Claude Code CLI, Codex
# app-server) and the read-only session-store helpers (ZCode, Codex) —
# all exercised against stubbed processes and temp SQLite databases, so no
# external binaries or credentials are needed.
class ExternalAdaptersTest < Minitest::Test
  # ── Fake processes ──

  FakeProc = Struct.new(:pid, :alive) do
    def alive? = alive
    def join(*) = self
  end

  # A fake Open3 result: three StringIO-ish objects + a process handle.
  # to_ary lets callers destructure it like a real popen3 result.
  class FakeProcess
    attr_reader :stdin, :stdout, :stderr, :wait_thr

    def initialize(stdin:, stdout:, stderr:, wait_thr:)
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @wait_thr = wait_thr
    end

    def to_ary = [@stdin, @stdout, @stderr, @wait_thr]

    def self.from_lines(lines)
      out = StringIO.new(lines.join("\n") + "\n")
      thr = FakeProc.new(1234, true)
      new(stdin: StringIO.new, stdout: out, stderr: StringIO.new, wait_thr: thr)
    end
  end

  def stub_open3(process)
    Open3.stubs(:popen3).returns(process)
  end

  # ── Claude Code adapter (stream-json CLI) ──

  def test_claude_adapter_streams_assistant_and_completes
    events = [
      { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "Hello " }] } },
      { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "world" }] } },
      { "type" => "result", "is_error" => false, "result" => "done" }
    ]
    stub_open3(FakeProcess.from_lines(events.map { |e| JSON.generate(e) }))

    adapter = Ask::CodingProviders::Claude::Adapter.new(cli_path: "claude", cwd: ".")
    adapter.start
    sid = adapter.create_session("/tmp")

    collected = []
    adapter.send_and_stream(sid, "hi") { |ev| collected << ev }

    types = collected.map { |e| e[:type] }
    assert_includes types, "turn.started"
    assert_includes types, "model.streaming"
    assert_includes types, "turn.completed"
    deltas = collected.select { |e| e[:type] == "model.streaming" }.map { |e| e.dig(:payload, "delta") }.join
    assert_equal "Hello world", deltas
  end

  def test_claude_adapter_reports_result_errors
    events = [{ "type" => "result", "is_error" => true, "result" => "boom" }]
    stub_open3(FakeProcess.from_lines(events.map { |e| JSON.generate(e) }))

    adapter = Ask::CodingProviders::Claude::Adapter.new
    adapter.start
    sid = adapter.create_session("/tmp")

    collected = []
    adapter.send_and_stream(sid, "hi") { |ev| collected << ev }
    failed = collected.find { |e| e[:type] == "turn.failed" }
    assert_equal "boom", failed.dig(:payload, "error", "message")
  end

  def test_claude_adapter_reports_stream_errors
    events = [{ "type" => "error", "message" => "api error" }]
    stub_open3(FakeProcess.from_lines(events.map { |e| JSON.generate(e) }))

    adapter = Ask::CodingProviders::Claude::Adapter.new
    adapter.start
    sid = adapter.create_session("/tmp")

    collected = []
    adapter.send_and_stream(sid, "hi") { |ev| collected << ev }
    failed = collected.find { |e| e[:type] == "turn.failed" }
    assert_equal "api error", failed.dig(:payload, "error", "message")
  end

  def test_claude_adapter_ignores_garbage_lines
    stub_open3(FakeProcess.from_lines(["not json", "", "   "]))

    adapter = Ask::CodingProviders::Claude::Adapter.new
    adapter.start
    sid = adapter.create_session("/tmp")
    collected = []
    adapter.send_and_stream(sid, "hi") { |ev| collected << ev }
    assert_equal ["turn.started"], collected.map { |e| e[:type] }
  end

  def test_claude_adapter_lifecycle
    adapter = Ask::CodingProviders::Claude::Adapter.new
    refute adapter.running?
    assert_raises(Ask::CodingProviders::Claude::Error) { adapter.create_session("/tmp") }
    adapter.start
    assert adapter.running?
    sid = adapter.create_session("/tmp")
    assert_match(/^sess_/, sid)
    assert_equal({}, adapter.resume_session("nope"))
    adapter.stop
    refute adapter.running?
  end

  # ── Codex adapter (app-server client) ──

  def test_codex_adapter_lifecycle_and_send
    client = stub("app-server-client")
    client.stubs(:start)
    client.stubs(:stop)
    client.stubs(:running?).returns(true)
    client.stubs(:initialize!)
    client.stubs(:send_initialized)
    client.stubs(:thread_start).with(cwd: "/tmp").returns({ "id" => "codex_1" })
    client.stubs(:thread_resume).with("codex_1").returns({ "id" => "codex_1" })
    client.stubs(:turn_start).with("codex_1", "hello").returns({ "turnId" => "t1" })
    client.stubs(:read_workspace_state).returns({ "model" => "x" })
    client.stubs(:request).with("session/create", anything).returns({ "sessionId" => "codex_1" })
    client.stubs(:request).with("session/respond", anything).returns({})
    client.stubs(:request).with("session/events", anything).returns({ "events" => [] })
    client.stubs(:on_notification)

    Ask::CodingProviders::Codex::AppServerClient.stubs(:new).returns(client)

    # The adapter reads the machine's Codex session DB for listings — stub
    # it so tests never touch real user data.
    db = stub("codex-db")
    db.stubs(:available?).returns(false)
    db.stubs(:list_projects).returns([])
    db.stubs(:find_sessions).returns([])
    db.stubs(:find_recent_session).returns(nil)
    db.stubs(:find_recent_tui_session).returns(nil)
    db.stubs(:session_directory).returns(nil)
    db.stubs(:session_history).returns([])
    db.stubs(:recent_sessions).returns([])
    Ask::CodingProviders::Codex::CodexDB.stubs(:new).returns(db)

    adapter = Ask::CodingProviders::Codex::Adapter.new(cwd: "/tmp")
    adapter.start
    assert adapter.running?

    sid = adapter.create_session("/tmp")
    assert_equal "codex_1", sid
    assert_equal({ "id" => "codex_1" }, adapter.resume_session(sid))

    result = adapter.send_message(sid, "hello")
    assert result.is_a?(Hash)

    assert_equal({}, adapter.get_events(sid, after_seq: 0))
    assert_equal({ "model" => "x" }, adapter.get_workspace_state("/tmp"))
    assert_equal [], adapter.list_projects
    assert_equal [], adapter.find_sessions(directory: "/tmp")

    adapter.stop
  end

  # ── ZCode session store (read-only SQLite) ──

  def build_zcode_db
    dir = Dir.mktmpdir("zcode-test")
    path = File.join(dir, "db.sqlite")
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE session (
        id TEXT PRIMARY KEY, project_id TEXT, directory TEXT, title TEXT,
        time_updated INTEGER, time_archived INTEGER, task_type TEXT
      );
      CREATE TABLE message (
        id TEXT PRIMARY KEY, session_id TEXT, data TEXT
      );
      CREATE TABLE part (
        id TEXT PRIMARY KEY, session_id TEXT, message_id TEXT,
        data TEXT, time_created INTEGER
      );
      INSERT INTO session VALUES ('s1','p1','/proj/a','First session',100,NULL,'interactive');
      INSERT INTO session VALUES ('s2','p1','/proj/a','Archived',200,150,'interactive');
      INSERT INTO session VALUES ('s3','p2','/proj/b','Other',300,NULL,'interactive');
    SQL
    [path, db]
  end

  def test_zcode_db_queries
    path, db = build_zcode_db
    db.execute_batch(<<~SQL)
      INSERT INTO message VALUES ('m1','s1','{"role":"user","semantics":{"origin":"real_user"}}');
      INSERT INTO part VALUES ('p1','s1','m1','{"type":"text","text":"hello from zcode"}',100);
    SQL
    db.close

    z = Ask::CodingProviders::ZCode::ZCodeDB.new(path)
    assert z.available?

    projects = z.list_projects
    assert_kind_of Array, projects
    counts = projects.to_h { |p| [p[:project_id], p[:session_count]] }
    assert_equal 1, counts["p1"]
    assert_equal 1, counts["p2"]

    sessions = z.find_sessions(directory: "/proj/a")
    assert_equal ["s1"], sessions.map { |s| s[:session_id] }

    recent = z.find_recent_session
    assert_equal "s3", recent[:session_id]

    tui = z.find_recent_tui_session("/proj/a")
    assert_equal "s1", tui[:session_id]

    assert_equal "/proj/a", z.session_directory("s1")
    assert_nil z.session_directory("nope")

    history = z.session_history("s1")
    assert_equal 1, history.length
    assert_equal "hello from zcode", history.first[:text]
    assert_equal "You", history.first[:role]

    assert z.recent_sessions.any? { |r| r[:session_id] == "s1" }
  ensure
    FileUtils.rm_rf(path ? File.dirname(path) : nil)
  end

  def test_zcode_db_missing_file_is_safe
    z = Ask::CodingProviders::ZCode::ZCodeDB.new("/nonexistent/db.sqlite")
    refute z.available?
    assert_equal [], z.list_projects
    assert_equal [], z.find_sessions(directory: "/tmp")
    assert_nil z.find_recent_session
    assert_equal [], z.recent_sessions
  end

  # ── Codex session store (threads table + rollout JSONL) ──

  def build_codex_db
    dir = Dir.mktmpdir("codex-test")
    rollout = File.join(dir, "rollout.jsonl")
    File.write(rollout, [
      JSON.generate({ "type" => "user_message", "content" => "question" }),
      JSON.generate({ "type" => "agent_message", "content" => "answer" }),
      "not json at all"
    ].join("\n") + "\n")

    path = File.join(dir, "codex.sqlite")
    db = SQLite3::Database.new(path)
    db.execute_batch(<<~SQL)
      CREATE TABLE threads (
        id TEXT PRIMARY KEY, cwd TEXT, title TEXT, preview TEXT,
        updated_at INTEGER, archived INTEGER, rollout_path TEXT
      );
      INSERT INTO threads VALUES ('t1','/proj/x','Task one','preview',100,0,'#{rollout}');
      INSERT INTO threads VALUES ('t2','/proj/y','',NULL,50,0,NULL);
    SQL
    db.close
    [path, rollout]
  end

  def test_codex_db_queries
    path, rollout = build_codex_db

    c = Ask::CodingProviders::Codex::CodexDB.new(path)
    assert c.available?

    projects = c.list_projects
    assert_equal 2, projects.length
    counts = projects.to_h { |p| [p[:directory], p[:session_count]] }
    assert_equal 1, counts["/proj/x"]
    assert_equal 1, counts["/proj/y"]

    sessions = c.find_sessions(directory: "/proj/x")
    assert_equal ["t1"], sessions.map { |s| s[:session_id] }

    recent = c.find_recent_session
    assert_equal "t1", recent[:session_id]

    tui = c.find_recent_tui_session("/proj/x")
    assert_equal "t1", tui[:session_id]

    assert_equal "/proj/x", c.session_directory("t1")

    history = c.session_history("t1")
    assert_equal 2, history.length
    assert_equal "question", history.first[:text]
    assert_equal "answer", history.last[:text]

    recents = c.recent_sessions
    assert_equal "Task one", recents.first[:title]
    assert recents.any? { |r| r[:title] == "(untitled)" }
  ensure
    FileUtils.rm_rf(path ? File.dirname(path) : nil)
  end

  def test_codex_db_missing_file_is_safe
    c = Ask::CodingProviders::Codex::CodexDB.new("/nonexistent/codex.sqlite")
    refute c.available?
    assert_equal [], c.list_projects
    assert_equal [], c.find_sessions(directory: "/tmp")
    assert_nil c.find_recent_session
    assert_nil c.session_directory("nope")
  end
end
