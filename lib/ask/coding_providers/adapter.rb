# frozen_string_literal: true

module Ask
  module CodingProviders
    # Abstract base class for coding agent adapters.
    #
    # A coding agent adapter wraps an AI coding agent (e.g., ZCode, Claude Code, Codex)
    # and provides a uniform interface for the coder engine to interact with it.
    #
    # Subclasses must implement all methods that raise NotImplementedError.
    class Adapter
      # Create a new session on the agent.
      #
      # @param workspace_path [String] the working directory
      # @param mode [String, nil] permission mode
      # @return [String] the session ID
      def create_session(workspace_path, mode: nil)
        raise NotImplementedError, "#{self.class} must implement #create_session"
      end

      # Resume an existing session.
      #
      # @param session_id [String] the session ID
      # @return [Hash] session snapshot
      def resume_session(session_id)
        raise NotImplementedError, "#{self.class} must implement #resume_session"
      end

      # List available sessions.
      #
      # @param workspace_path [String, nil] optional filter
      # @param limit [Integer] max sessions
      # @return [Array<Hash>] session summaries
      def list_sessions(workspace_path: nil, limit: 20)
        raise NotImplementedError, "#{self.class} must implement #list_sessions"
      end

      # Subscribe to session events.
      #
      # @param session_id [String] the session ID
      # @param after_seq [Integer] sequence to start from
      # @return [Hash] subscription result
      def subscribe(session_id, after_seq: 0)
        raise NotImplementedError, "#{self.class} must implement #subscribe"
      end

      # Send a message to a session (fire-and-forget).
      def send_message(session_id, content)
        raise NotImplementedError, "#{self.class} must implement #send_message"
      end

      # Send a message and stream the response events.
      #
      # @yield [Hash] stream events with :type, :payload, :seq
      def send_and_stream(session_id, content, turn_timeout: 600.0, &block)
        raise NotImplementedError, "#{self.class} must implement #send_and_stream"
      end

      # Get events after a sequence number (polling).
      #
      # @return [Hash] events list
      def get_events(session_id, after_seq:, limit: nil)
        raise NotImplementedError, "#{self.class} must implement #get_events"
      end

      # Respond to a reverse request (permission approval, etc.).
      def respond(request_id, result)
        raise NotImplementedError, "#{self.class} must implement #respond"
      end

      # Read the workspace state (model info, settings, etc.).
      def get_workspace_state(workspace_path)
        {}
      end

      # Called when a session operation fails. The adapter can signal how
      # the Engine should recover.
      #
      # @param session_id [String] the session that failed
      # @param error [StandardError] the error that occurred
      # @return [Symbol, nil] :create_new to replace the session, nil to show error as-is
      def handle_session_error(session_id, error)
        nil  # Unknown error — let the Engine show it to the user
      end

      # Optional: list available projects with session counts.
      # Returns [{project_id:, directory:, session_count:}] or nil.
      def list_projects
        nil
      end

      # Optional: find sessions in a directory.
      # Returns [{session_id:, title:, updated:}] or [].
      def find_sessions(directory:, limit: 20)
        []
      end

      # Optional: find the single most recent session.
      # Returns {session_id:, directory:} or nil.
      def find_recent_session
        nil
      end

      # Optional: find the most recent TUI session in a workspace.
      # Returns {session_id:, title:, directory:} or nil.
      def find_recent_tui_session(workspace_path)
        nil
      end

      # Optional: get a session's workspace directory by ID.
      # Returns directory string or nil.
      def session_directory(session_id)
        nil
      end

      # Optional: get session message history.
      # Returns [{text:, role:, origin:}] or [].
      def session_history(session_id, limit: 100)
        []
      end

      # Optional: list recent sessions across all projects.
      # Returns [{session_id:, title:, updated:, msg_count:}] or [].
      def recent_sessions
        []
      end

      # Start the agent connection.
      def start
      end

      # Stop the agent connection.
      def stop
      end

      # Whether the agent is running.
      def running?
        true
      end
    end
  end
end
