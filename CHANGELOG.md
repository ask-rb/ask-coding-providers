# Changelog

## [0.2.0] - 2026-08-10

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
