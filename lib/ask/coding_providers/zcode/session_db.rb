# frozen_string_literal: true

require "json"

module Ask
  module CodingProviders
    module ZCode
      # Wraps the ZCode SQLite database, centralizing all session/project queries.
      #
      # Usage:
      #   db = SessionDB.new
      #   projects = db.list_projects
      #   sessions = db.find_sessions(directory: "/path")
      #
      # All methods return nil or empty arrays on error (never raise).
      # This makes it safe to use from any context without wrapping every call.
      class SessionDB
      def initialize(db_path = nil)
        @db_path = db_path || File.expand_path("~/.zcode/cli/db/db.sqlite")
      end

      def available?
        File.exist?(@db_path)
      end

      # List all projects with session counts, ordered by most recently updated.
      # Returns [{project_id:, directory:, session_count:}] or [].
      def list_projects
        return [] unless available?

        db = open_db
        rows = db.execute(<<~SQL)
          SELECT project_id, directory, count(*) as session_count
          FROM session
          WHERE task_type = 'interactive' AND time_archived IS NULL
          GROUP BY project_id
          ORDER BY MAX(time_updated) DESC
          LIMIT 10
        SQL
        rows.map { |r| { project_id: r["project_id"], directory: r["directory"], session_count: r["session_count"].to_i } }
      rescue => e
        nil
      ensure
        db&.close
      end

      # Find sessions in a given directory (exact or prefix match).
      # Returns [{session_id:, title:, updated:}] or [].
      def find_sessions(directory:, limit: 20)
        return [] unless available?

        db = open_db
        rows = db.execute(<<~SQL, [directory, directory, limit])
          SELECT id, title, time_updated
          FROM session
          WHERE (directory = ? OR ? LIKE directory || '/%')
            AND time_archived IS NULL AND task_type = 'interactive'
          ORDER BY time_updated DESC
          LIMIT ?
        SQL
        rows.map { |r| { session_id: r["id"], title: r["title"], updated: r["time_updated"] } }
      rescue => e
        []
      ensure
        db&.close
      end

      # Find the single most recent session across all projects.
      # Returns {session_id:, directory:} or nil.
      def find_recent_session
        return nil unless available?

        db = open_db
        row = db.get_first_row(<<~SQL)
          SELECT id, directory FROM session
          WHERE time_archived IS NULL AND task_type = 'interactive'
          ORDER BY time_updated DESC LIMIT 1
        SQL
        row ? { session_id: row["id"], directory: row["directory"] } : nil
      rescue => e
        nil
      ensure
        db&.close
      end

      # Find the most recent TUI session in a workspace path.
      # Returns {session_id:, title:, directory:} or nil.
      def find_recent_tui_session(workspace_path)
        return nil unless available?

        db = open_db
        row = db.get_first_row(<<~SQL, [workspace_path, workspace_path])
          SELECT id, title, directory
          FROM session
          WHERE (directory = ? OR ? LIKE directory || '/%')
            AND time_archived IS NULL AND task_type = 'interactive'
          ORDER BY time_updated DESC
          LIMIT 1
        SQL
        row ? { session_id: row["id"], title: row["title"], directory: row["directory"] } : nil
      rescue => e
        nil
      ensure
        db&.close
      end

      # Look up a session's workspace directory by its ID.
      # Returns the directory string, or nil.
      def session_directory(session_id)
        return nil unless available?

        db = open_db
        row = db.get_first_row("SELECT directory FROM session WHERE id = ?", [session_id])
        row&.dig("directory")
      rescue => e
        nil
      ensure
        db&.close
      end

      # Load the last N text parts from a session, newest first.
      # Returns [{text:, role:, origin:}] or [].
      def session_history(session_id, limit: 100)
        return [] unless available?

        db = open_db
        rows = db.execute(<<~SQL, [session_id, limit])
          SELECT p.data, m.data as msg_data FROM part p
          JOIN message m ON p.message_id = m.id
          WHERE p.session_id = ? AND p.data LIKE '%"type":"text"%'
          ORDER BY p.time_created DESC
          LIMIT ?
        SQL

        rows.filter_map do |r|
          part = JSON.parse(r["data"]) rescue next
          content = part["text"] || ""
          next if content.empty?

          msg_data = JSON.parse(r["msg_data"]) rescue {}
          role = msg_data["role"] == "user" ? "You" : "Agent"
          origin = msg_data.dig("semantics", "origin") rescue nil

          # Skip system-generated messages masquerading as user
          next if role == "You" && origin != "real_user" && origin != nil

          { text: content, role: role, origin: origin }
        end
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
          SELECT s.id AS session_id, s.title AS title,
                 s.time_updated AS updated,
                 (SELECT count(*) FROM message m WHERE m.session_id = s.id) AS msg_count
          FROM session s
          WHERE s.task_type = 'interactive' AND s.time_archived IS NULL
          ORDER BY s.time_updated DESC
          LIMIT 20
        SQL
        rows.map do |r|
          {
            session_id: r["session_id"],
            title: r["title"],
            updated: r["updated"],
            msg_count: r["msg_count"].to_i
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
	    end
	  end
	end
	end
