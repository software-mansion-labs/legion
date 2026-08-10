# Changelog

## Unreleased

### Changes

- Make sandboxes pluggable: `Legion.Sandbox` is now a behaviour selected per agent (or globally) with the `sandbox` config key, opening the door to sandboxes such as [popcorn](https://github.com/software-mansion/popcorn/) in the user's browser. The Elixir implementation moved to `Legion.Sandbox.Elixir`, and the process isolation with timeout / memory / CPU budgets was extracted to `Legion.Sandbox.Runner`, shared by all sandboxes
- Add `Legion.Sandbox.Lua` - agents write Lua evaluated by [lua](https://hexdocs.pm/lua), a Lua 5.3 VM in pure Elixir. Generated code cannot reach the host BEAM at all (no AST allowlist to escape); tools are bridged in as global Lua tables with values converted at the boundary
- Make `Legion.Sandbox.Lua` the default sandbox. Agents now write Lua unless configured otherwise; set `sandbox: Legion.Sandbox.Elixir` (per agent or globally) to keep agents writing Elixir. Note that only `Legion.Tool` modules are callable from Lua - plain modules passed as tools (e.g. `Jason`) are reference-only there
- Add `Legion.Store` for persisting conversations across process and application restarts; stores exchange partial `Legion.Store.Payload` values containing conversation state and metadata through `get/1` and `save/1`
- Persist the user message with `status: :running` before execution and the final conversation with `status: :idle` before replying, so a reply is a commit receipt for the completed turn
- Add optional `persistence_frequency/0`; stores default to `:turn`, while `:step` also checkpoints intermediate eval results, recoverable errors, bindings, and executor progress. Interrupted turns are recorded but are not resumed automatically
- Add globally configured and per-agent stores, generated agent ids, `Legion.get_agent_id/1`, `Legion.lookup/1`, `Legion.running?/1`, and `Legion.resume/2` for identifying, finding, and restarting persisted conversations
- Propagate stores to sub-agents and persist `parent_agent_id`, `agent_module`, and `started_at` metadata for reconstructing conversation trees
- Add `Legion.Store.Postgres`, backed by an existing PostgreSQL Ecto repo, with partial upserts, `get/1`, `list/1`, configurable table names, configurable persistence frequency, and an optional `ecto_sql` dependency
- Add versioned, idempotent `Legion.Store.Migration.Postgres` migrations with configurable table names and `pg_notify` notifications for inserts and updates; migration versions are tracked in the agents table comment; generated stores expose `__repo__/0` and `__table__/0` for database-backed consumers such as LegionWeb
- Bump the default model from `openai:gpt-4o-mini` to `openai:gpt-5.4`
- `Legion.Tools.HumanTool.ask/1` now raises when called under `eval_and_complete` - the turn would end as soon as the code returns, silently discarding the human's answer; the error feeds back to the model, which retries under `eval_and_continue`

## v0.4.0 - 2026-05-17

### Security

- Harden `Legion.Sandbox.ASTChecker` against a class of RCE paths. After this release, most (if not all) RCE vectors should be closed. Legion is still vulnerable to DoS kinds of attacks, but we assume that having a system prompt instruction to behave well AND improving sandbox should be enough for now.

### Changes

- Broaden the sandbox surface for common LLM idioms: allow `Map.values/1`, `JSON`, `URI`, `:erlang.float_to_binary/2`, additional `String`/`Enum`/`Date`/`DateTime` functions, and the `Access` protocol (`map[:k]`)
- Document the sandbox constraints with concrete idioms in the system prompt
- Fix tool source extraction breaking on heredocs and charlists
- Correct documentation for telemetry events, source registry, and `AgentTool.start_link/2`

## v0.3.0 - 2026-04-21

### Changes

- Replace `share_bindings` boolean with `binding_scope` (`:iteration`, `:turn`, `:conversation`) for fine-grained control over variable lifetime across code executions
- Add `action_types/0` callback to restrict which actions an agent can use (e.g. `~w(return done)` for read-only agents)
- Add `max_message_length` config with truncation support to prevent unbounded message growth
- Add multimedia message support: `{:image, data, media_type}`, `{:image_url, url}`, and `{:multipart, parts}`
- Add `Legion.get_messages/1` to retrieve conversation history from a running agent
- Expand `AgentTool` with `parallel/2`, `pipeline/1`, `then/3`, and `extra_allowed_modules/0` for sub-agent orchestration; sub-agents are auto-aliased in the sandbox
- Generate dynamic `AgentTool.description/0` from sub-agent moduledocs
- Move system prompt resolution to `AgentPrompt`, respecting custom `system_prompt/0` overrides
- Validate config keys at startup with warnings for unknown keys
- Add `@moduledoc` compile-time validation via `__before_compile__`
- Harden sandbox: block `def`/`defp`/`__ENV__`, additional `:erlang` functions (`process_flag`, `list_to_atom`, `system_info`), catch throws and exits, surface compiler diagnostics on errors
- Handle executor exceptions gracefully instead of crashing the agent loop
- Add `Calendar` to sandbox safe-module list
- Emit `:exception` telemetry events for iteration, LLM, and sandbox spans; use `System.convert_time_unit/3` for duration reporting
- Extensive new test coverage for `AgentServer`, `Executor`, `Sandbox`, and `ASTChecker`

## v0.2.1 - 2026-03-24

- Improve source code extraction for tool definitions
- Adjust system prompt to better reflect capabilities


## v0.2.0 - 2026-03-15

### Changes

- Simplified and refactored internals
- Improved documentation and general library intent

---

## v0.1.0 - 2025-12-29

### New 🔥

- Initial release of Legion - an Elixir-native agentic AI framework
- `Legion.AIAgent` behaviour for building AI agents with customizable tools and configurations
- `Legion.Tool` behaviour for defining tools that agents can use
- Integration with `req_llm` for LLM communication
- `Legion.Sandbox` for secure code evaluation using Dune
- `Legion.call/2` and `Legion.cast/2` for synchronous and asynchronous message passing
- `Legion.start_link/2` for spawning long-lived agents
- Telemetry events for monitoring and debugging agent execution
- Support for agent-to-agent communication and delegation
