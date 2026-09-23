# Changelog

## [Unreleased]

### Added

- **Approval scopes on the AskAgent adapter.** `approve_action` and
  `approve_all` accept `scope: :once | :session` (default `:once`) and
  pass it through to `Ask::Permissions::ApprovalQueue#approve` /
  `#approve_all`. `:session` records a session grant — applied by
  `Ask::Agent::Session` before the approved action runs — so matching
  actions later in the session are auto-approved; `:once` stays
  one-shot. `:project` raises `ArgumentError` in this adapter: project
  grants are never injected here, so accepting it would be a silent
  no-op.

## [0.3.5] - 2026-09-23

### Changed

- **Approval queue extracted to `ask-permissions`.** The AskAgent adapter's
  `EmittingApprovalQueue` now subclasses `Ask::Permissions::ApprovalQueue`
  (docs reference `Ask::Permissions::Action`) instead of the ask-agent
  classes. The gem declares a runtime dependency on `ask-permissions >= 0.1.0`
  (local path in the Gemfile for development). Queue API and approval
  event/callback behavior are unchanged.

## [0.3.2] - 2026-08-10

### Added

- **Declarative agent sessions.** `create_session` accepts an `agent:`
  name — the ask-agent convention (`agents/<name>/agent.rb` +
  `instructions.md`, discovered from the working directory). The session
  is built via `Ask::Agent.new`, so the definition's tools, skills
  (agent_dir), and instructions apply, while harness-level options
  (model, system prompt, approval, plan mode, todos) still win. The
  emitting approval queue is passed through, so approval events stream
  exactly like the plain path.



### Added

- **Per-session system prompts.** `create_session` accepts a
  `system_prompt:` override for the session (takes precedence over the
  adapter-level  session option), so hosts like
  ask-coding-harness can give every workspace its own instructions.



### Fixed

- **Claude adapter streamed nothing** — the inner `each do |block|` loop
  shadowed the method's `&block` parameter, so `block.call` invoked the
  content Hash and every streaming turn failed. The loop variable is now
  `content_block`; `model.streaming` events stream correctly.
- **Codex session store** — `find_sessions` bound 2 parameters for 3 SQL
  placeholders (silently returned `[]`); `find_recent_tui_session` passed
  bind variables as separate arguments to `get_first_row` (silently
  returned `nil`). Both now bind correctly.

### Added

- **External adapter tests** — Claude Code CLI streaming (stubbed
  processes), Codex app-server client lifecycle, and read-only ZCode/Codex
  session-store queries against temp SQLite fixtures. Full suite passes
  the 70% coverage gate.


### Added

- **Rich event stream from the `ask_agent` adapter.** Sessions now emit
  `model.thinking`, `tool.use`, `tool.delta`, `tool.result` (with
  `isError`/`durationMs`), `approval.required`, `approval.updated`,
  `plan.proposed`, `plan.approved`, `plan.rejected`, `todos.updated`,
  `turn.aborted`, and `error` events in addition to the existing
  `model.streaming`/`turn.completed`/`turn.failed`. Existing consumers keep
  working unchanged.
- **Persistent in-process sessions.** Each `create_session` id maps to one
  `Ask::Agent::Session` instance whose conversation history accumulates
  across turns.
- **Approval controls.** `approve_action`, `reject_action`, `approve_all`,
  `reject_all`, `pending_approvals`, plus `approve_plan`/`reject_plan`/
  `pending_plan` for plan mode. `approval:` accepts `:off`, `:require`
  (tools listed in `approval_required:` queue for human review), or `:auto`
  (queue exists, never blocks).
- **Plan mode and todos.** `plan_mode:` and `todos:` pass through to the
  session and their events stream to subscribers.
- **Abort support.** `abort(session_id)` stops the current turn, which
  emits `turn.aborted`.
- **Turn completion waits for approvals.** `send_and_stream` keeps the
  stream open until the turn fully settles (follow-up turns included),
  bounded by `turn_timeout`.

### Fixed

- `turn.started` is emitted after subscribing, so subscribers always
  receive it.
- Sessions created but never run no longer crash `list_sessions` /
  `session_history`.
- Approval mode is validated at adapter construction (fail fast).
- Session listing sorts deterministically.
