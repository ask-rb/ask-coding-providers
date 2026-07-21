# frozen_string_literal: true

require "json"
require "open3"

module Ask
  module CodingProviders
    module ZCode
      # ZCode CLI --prompt mode client (fallback when app-server is unavailable).
      class Client
        Result = Struct.new(
          :response, :session_id, :usage, :projection, :raw,
          keyword_init: true
        ) do
          def total_tokens
            (usage.is_a?(Hash) ? (usage["totalTokens"] || usage[:totalTokens] || 0) : 0).to_i
          end

          def error?
            raw.is_a?(Hash) && (raw["isError"] || raw[:isError])
          end
        end

        def initialize(working_dir: ".", timeout: 600, cli_path: nil)
          @working_dir = working_dir
          @timeout = timeout
          @cli_path = cli_path || AppServerClient.resolve_cli_path
        end

        def run(prompt, session_id: nil)
          args = build_args(prompt, session_id)
          stdout, stderr, status = Open3.capture3(*args, chdir: @working_dir)
          parse_output(status, stdout, stderr)
        end

        private

        def build_args(prompt, session_id)
          cli = @cli_path
          args = cli.end_with?(".cjs") ? ["node", "--experimental-sqlite", cli] : [cli]
          args += ["--resume", session_id] if session_id
          args += ["--prompt", prompt, "--json", "--no-color"]
          args
        end

        def parse_output(status, stdout, stderr)
          if stdout && !stdout.strip.empty?
            begin
              data = JSON.parse(stdout)
              return Result.new(
                response: data["response"] || "",
                session_id: data["sessionId"] || "",
                usage: data["usage"] || {},
                projection: data["projection"] || {},
                raw: data
              )
            rescue JSON::ParserError
            end
          end

          raise CLIError,
            "ZCode execution failed (exit=#{status.exitstatus}).\n#{stderr.strip[0..500]}"
        end
      end
    end
  end
end
