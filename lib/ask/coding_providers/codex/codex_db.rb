# frozen_string_literal: true

require "json"

module Ask
  module CodingProviders
    module Codex
      # Queries Codex's SQLite database for thread/project data.
      #
      # Codex stores sessions in `~/.codex/state_5.sqlite` (threads table)
      # and full message history in JSONL rollout files.
      class CodexDB
        DEFAULT_DB = File.expand_path("~/.codex/state_5.sqlite")

        def initialize(db_path = nil)
          @db_path = db_path || DEFAULT_DB
        end

        def available?
          File.exist?(@db_path)
        end

        # List all projects (directories with threads), ordered by most recent.
        # Returns [{project_id:, directory:, session_count:}] or [].
        def list_projects
          return [] unless available?

          db = open_db
          rows = db.execute(<<~SQL)
            SELECT cwd AS directory,
                   COUNT(*) AS session_count,
                   MAX(updated_at) AS last_active
            FROM threads
            WHERE archived = 0
            GROUP BY cwd
            ORDER BY last_active DESC
            LIMIT 20
          SQL
          rows.map do |r|
            {
              project_id: r["directory"],
              directory: r["directory"],
              session_count: r["session_count"].to_i
            }
          end
        rescue => e
          []
        ensure
          db&.close
        end

        # Find sessions in a given directory.
        # Returns [{session_id:, title:, updated:}] or [].
        def find_sessions(directory:, limit: 20)
          return [] unless available?

          db = open_db
          rows = db.execute(<<~SQL, [directory, directory])
            SELECT id, title, updated_at, preview
            FROM threads
            WHERE (cwd = ? OR ? LIKE cwd || '/%')
              AND archived = 0
            ORDER BY updated_at DESC
            LIMIT ?
          SQL
          rows.map do |r|
            {
              session_id: r["id"],
              title: r["title"].to_s.empty? ? (r["preview"] || "(untitled)") : r["title"],
              updated: r["updated_at"]
            }
          end
        rescue => e
          []
        ensure
          db&.close
        end

        # Find the most recent session across all projects.
        # Returns {session_id:, directory:} or nil.
        def find_recent_session
          return nil unless available?

          db = open_db
          row = db.get_first_row(<<~SQL)
            SELECT id, cwd FROM threads
            WHERE archived = 0
            ORDER BY updated_at DESC LIMIT 1
          SQL
          row ? { session_id: row["id"], directory: row["cwd"] } : nil
        rescue => e
          nil
        ensure
          db&.close
        end

        # Find the most recent TUI session in a workspace.
        def find_recent_tui_session(workspace_path)
          return nil unless available?

          db = open_db
          row = db.get_first_row(<<~SQL, workspace_path, workspace_path)
            SELECT id, title, cwd FROM threads
            WHERE (cwd = ? OR ? LIKE cwd || '/%')
              AND archived = 0
            ORDER BY updated_at DESC LIMIT 1
          SQL
          return nil unless row
          {
            session_id: row["id"],
            title: row["title"],
            directory: row["cwd"]
          }
        rescue => e
          nil
        ensure
          db&.close
        end

        # Look up a session's workspace directory by ID.
        def session_directory(session_id)
          return nil unless available?

          db = open_db
          row = db.get_first_row("SELECT cwd FROM threads WHERE id = ?", [session_id])
          row&.dig("cwd")
        rescue => e
          nil
        ensure
          db&.close
        end

        # Get session message history from the rollout JSONL file.
        # Returns [{text:, role:, origin:}] or [].
        def session_history(session_id, limit: 100)
          return [] unless available?

          db = open_db
          row = db.get_first_row("SELECT rollout_path, title, preview FROM threads WHERE id = ?", [session_id])
          return [] unless row

          rollout_path = row["rollout_path"]
          return [] unless rollout_path && File.exist?(rollout_path)

          parse_rollout(rollout_path, limit)
        rescue => e
          []
        ensure
          db&.close
        end

        # List recent sessions across all projects.
        # Returns [{session_id:, title:, updated:, msg_count:}] or [].
        def recent_sessions
          return [] unless available?

          db = open_db
          rows = db.execute(<<~SQL)
            SELECT id, title, updated_at, preview
            FROM threads
            WHERE archived = 0
            ORDER BY updated_at DESC
            LIMIT 50
          SQL
          rows.map do |r|
            {
              session_id: r["id"],
              title: r["title"].to_s.empty? ? (r["preview"] || "(untitled)") : r["title"],
              updated: r["updated_at"],
              msg_count: 0
            }
          end
        rescue => e
          []
        ensure
          db&.close
        end

        private

        def open_db
          require "sqlite3"
          db = SQLite3::Database.new(@db_path, readonly: true)
          db.results_as_hash = true
          db
        end

        def parse_rollout(path, limit)
          messages = []
          File.readlines(path).each do |line|
            begin
              event = JSON.parse(line)
            rescue JSON::ParserError
              next
            end

            case event["type"]
            when "user_message"
              messages << { text: event["content"].to_s, role: "You", origin: "real_user" }
            when "agent_message"
              messages << { text: event["content"].to_s, role: "Agent", origin: nil }
            end
            break if messages.length >= limit * 2
          end
          messages.last(limit)
        end
      end
    end
  end
end
