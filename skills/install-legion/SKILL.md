---
name: install-legion
description: Add Legion - Elixir AI agents that write sandboxed Lua against the app's own modules - to an existing Mix or Phoenix app. Wires the dependency, supervisor child, LLM key, optional Postgres store, optional LegionWeb dashboard and a first tool and agent over existing code, then verifies it compiles and answers. Use when asked to install, add, set up or integrate Legion (or legion_web) into an app.
---

# Install Legion into an existing app

Legion is one dependency, one supervisor child, an LLM key, and a few plain
modules next to the code the app already has. Nothing gets rewritten.
Work in this order and keep every edit minimal.

## 0. Look before editing

Read these first and decide the optional steps from what you find:

- `mix.exs` - is `:legion` already a dependency? Is there `:phoenix`?
  `:ecto_sql` with `:postgrex`? `:ash`? `:igniter`?
- `lib/*/application.ex` - the `children` list, where the Repo and the
  Endpoint sit.
- `config/runtime.exs`, `.env`, `.envrc` - an existing LLM key such as
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, `OPENROUTER_API_KEY`.
- `lib/*_web/router.ex` - the auth pipelines available (`phx.gen.auth` gives
  `:require_authenticated_user`).
- `git status` - start from a clean tree so the install is one reviewable diff.

Decisions, in the user's terms, before touching anything:

| Found                        | Do                                                    |
| ---------------------------- | ----------------------------------------------------- |
| Postgres Ecto repo           | Step 4 - `Legion.Store.Postgres`                       |
| No Postgres repo             | Skip step 4; conversations live as long as the process |
| Phoenix router               | Step 5 - `legion_web` dashboard behind auth            |
| An LLM key in the environment| Configure that provider in step 3                      |
| No LLM key                   | Configure OpenAI and tell the user which variable to set |

Ask only when two readings lead to different work, for example two repos or
no obvious context to wrap in step 6.

## 1. Dependency

```elixir
# mix.exs
{:legion, "~> 0.5"}
```

Add `{:legion_web, "~> 0.5"}` when doing step 5. `Vault` arrives as a
dependency of Legion; declare `{:vault, "~> 0.2"}` explicitly only if the app
calls it from controllers or LiveViews. Then:

```bash
mix deps.get
```

## 2. Supervisor child

`Legion` is a supervisor. Put it after the Repo (recovery reads the store on
boot); its position relative to the Endpoint does not matter.

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  MyAppWeb.Endpoint,
  Legion
]
```

## 3. LLM provider key

Runtime config only, never `config.exs`, never a literal key. The key name is
`<provider>_api_key`. The default model is `openai:gpt-5.4`, so with OpenAI
nothing else is needed:

```elixir
# config/runtime.exs
config :req_llm, openai_api_key: System.get_env("OPENAI_API_KEY")
```

Another provider needs its key and a model in the `provider:model` form
ReqLLM accepts (see https://hexdocs.pm/req_llm):

```elixir
config :req_llm, anthropic_api_key: System.get_env("ANTHROPIC_API_KEY")
config :legion, :config, %{model: "anthropic:<model>"}
```

If the app already loads `.env` through `dotenvy` or similar, follow that
pattern instead of a bare `System.get_env/1`.

## 4. Postgres store (when the app has a Postgres Ecto repo)

Conversations then survive deploys and can be resumed by id.

```elixir
# lib/my_app/agent_store.ex
defmodule MyApp.AgentStore do
  use Legion.Store.Postgres, repo: MyApp.Repo
end

# config/config.exs
config :legion, :store, MyApp.AgentStore
```

```bash
mix ecto.gen.migration add_legion_agents
```

```elixir
def up, do: Legion.Store.Postgres.Migration.up()
def down, do: Legion.Store.Postgres.Migration.down()
```

```bash
mix ecto.migrate
```

The same table backs `Legion.RateLimiter.Postgres`, no extra migration. Add
it when untrusted users will drive agents; skip it for internal tools:

```elixir
defmodule MyApp.RateLimiter do
  use Legion.RateLimiter.Postgres, repo: MyApp.Repo
end

# config/config.exs
config :legion, :rate_limit,
  limiter: MyApp.RateLimiter,
  default_policy: %Legion.RateLimiter.Policy{
    window_ms: :timer.minutes(1),
    max_agents: 10,
    max_tokens: 100_000
  }
```

Rules naming the group (per user, per IP) go on every `Legion.start_link/2`
call; https://hexdocs.pm/legion/Legion.RateLimiter.html has the shape.

## 5. Dashboard (Phoenix only)

With `:igniter` in the project, `mix legion_web.install` adds the import and
a `/legion` route behind `:browser` alone; move that route into an
authenticated scope afterwards. Otherwise edit the router by hand:

```elixir
import LegionWeb.Router

scope "/" do
  pipe_through [:browser, :require_authenticated_user]
  legion_dashboard "/legion"
end
```

The dashboard shows every prompt, generated snippet and result. Never mount
it behind `:browser` alone. If the app has no auth pipeline, mount it
in a `dev`-only block or leave step 5 out and say so.

## 6. First tool and agent over existing code

Pick one context the user cares about (orders, tickets, catalog). Write a
small facade, not the context itself - the agent can call any public
function of a tool.

```elixir
# lib/my_app/tools/orders_tool.ex
defmodule MyApp.Tools.OrdersTool do
  use Legion.Tool

  @doc "Orders of the signed-in user, newest first"
  def my_orders do
    %{id: user_id} = Vault.get(:current_user)

    for order <- MyApp.Orders.list_orders(user_id: user_id) do
      %{id: order.id, status: order.status, placed_at: order.placed_at}
    end
  end
end

# lib/my_app/support_agent.ex
defmodule MyApp.SupportAgent do
  @moduledoc """
  Helps a signed-in user with their orders.
  Never invents order data - if a tool returns nothing, say so.
  """
  use Legion.Agent

  def tools, do: [MyApp.Tools.OrdersTool]
end
```

Rules that keep this safe and cheap:

- Identity comes from `Vault.get(:current_user)` inside the tool, never from
  a tool argument. Generated code cannot reach Vault.
- Return plain maps with the fields the agent needs. Tool results go into the
  prompt, so a `%User{}` with a password hash has no business there.
- Arguments arrive from Lua as string-keyed maps and tuples come back as
  lists. Do not pattern-match atom keys in a tool.
- Keep irreversible actions (charging, deleting, sending) out of tools or
  behind a confirmation step in the UI.
- Ash app: the tool calls the domain's code interface with
  `actor: Vault.get(:current_user)` so policies keep applying.

Calling it from a LiveView or controller, after the usual authentication:

```elixir
Vault.init(current_user: %{id: socket.assigns.current_user.id})
{:ok, pid} = Legion.start_link(MyApp.SupportAgent)
{:ok, reply} = Legion.call(pid, "Where is my latest order?")
```

`start_link/2` links the agent to the caller. To outlive a request, put it
under a `DynamicSupervisor` and pass `agent_id:` so step 4 can resume it.

## 7. Verify

```bash
mix format
mix compile --warnings-as-errors
```

With a key in the environment, one round trip proves the wiring end to end:

```bash
mix run -e 'IO.inspect(Legion.execute(MyApp.SupportAgent, "Return the sum of 2 and 2"))'
```

Expect `{:ok, "4"}`. A missing or wrong key comes back as
`{:error, "LLM request failed: ..."}` - report the exact variable the user
must set and stop there. Do not commit; leave the diff for review.

## Do not

- Switch the sandbox to `Legion.Sandbox.Elixir` unless asked. Lua is the
  default because it cannot reach the host BEAM.
- Expose a whole context module as a tool.
- Add `legion_web` without an authenticated pipeline.
- Add a rate limiter, store or dashboard the table in step 0 did not call for.

## Further reading

- Guides in the repo: https://github.com/software-mansion-labs/legion/tree/main/guides
  (`integrating.md`, `sandboxes.md`, `ash.md`)
- API docs: https://hexdocs.pm/legion
- Dashboard: https://github.com/software-mansion-labs/legion_web
