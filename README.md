# ask-coding-providers

[![Gem Version](https://badge.fury.io/rb/ask-coding-providers.svg)](https://badge.fury.io/rb/ask-coding-providers)

A registry of coding agent adapters for the ask-rb ecosystem. It provides a
uniform interface for driving AI coding agents (Claude Code, Codex, ACP-based
agents, ask_agent) and a read-only helper for reading ZCode's session store.

## Installation

```ruby
gem "ask-coding-providers"
```

## Quick Start

```ruby
require "ask-coding-providers"

# Build an adapter by registered name
adapter = Ask::CodingProviders.build_adapter("acp", workspace_path: Dir.pwd)
adapter = Ask::CodingProviders.build_adapter("ask_agent", model: "deepseek-v4-flash")

# The environment variable selects the adapter when none is given
# (see Ask::CodingProviders.resolve_adapter)
```

## Key entry points

- `Ask::CodingProviders.register_adapter(name, klass)` - register an adapter
  class under a name. Adapters register themselves when loaded.
- `Ask::CodingProviders.resolve_adapter(name)` - look up an adapter class.
  Raises `ConfigurationError` for unknown names and suggests setting the
  `CODING_PROVIDER` environment variable.
- `Ask::CodingProviders.build_adapter(name, **config)` - build an adapter
  instance, passing config options to the adapter's `.from_config`.
- Registered adapters: `:acp`, `:ask_agent`, `:claude`, `:codex`. There is no
  `:zcode` adapter.
- Adapter interface (`Ask::CodingProviders::Adapter`): `create_session`,
  `resume_session`, `list_sessions`, `subscribe`, `send_message`,
  `send_and_stream`, `get_events`, `respond`, `get_workspace_state`.
- `Ask::CodingProviders::ZCode::ZCodeDB` - read-only helper for querying
  ZCode's SQLite session store at `~/.zcode/cli/db/db.sqlite`. Methods
  (`list_projects`, `find_sessions`, `session_history`, `recent_sessions`,
  and others) return `nil` or empty arrays on error, never raising.
- `Ask::CodingProviders::Error`, `ConfigurationError`, `ConnectionError`, and
  `TimeoutError` - errors raised by the registry and adapters.

## Full documentation

The full ask-rb documentation lives at https://ask-rb.github.io/ask-docs.
[Reference: Gem Index](https://ask-rb.github.io/ask-docs/reference/gems)
covers ask-coding-providers in depth. API reference:
https://ask-rb.github.io/ask-docs/reference/api.

## Development

```
bundle install
bundle exec rake test
```

## License

MIT
