[![Ad](https://swm-delivery.com/www/images/zone-gh-legion-1?n=1)](https://swm-delivery.com/www/delivery/ck-slug.php?zoneid=zone-gh-legion-1&n=1)
[![Ad](https://swm-delivery.com/www/images/zone-gh-legion-2?n=1)](https://swm-delivery.com/www/delivery/ck-slug.php?zoneid=zone-gh-legion-2&n=1)
[![Ad](https://swm-delivery.com/www/images/zone-gh-legion-3?n=1)](https://swm-delivery.com/www/delivery/ck-slug.php?zoneid=zone-gh-legion-3&n=1)

# Legion

<div align="center">

[![CI](https://github.com/software-mansion-labs/legion/actions/workflows/ci.yml/badge.svg)](https://github.com/software-mansion-labs/legion/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/legion.svg)](https://github.com/software-mansion-labs/legion/blob/main/LICENSE)
[![Version](https://img.shields.io/hexpm/v/legion.svg)](https://hex.pm/packages/legion)
[![Hex Docs](https://img.shields.io/badge/documentation-gray.svg)](https://hexdocs.pm/legion)

</div>
<!-- MDOC -->

**Legion is an Elixir framework for AI agents that live inside your application and get things done by writing code.** 

Define an agent's responsibilities, give it tools to interact with your app safely, and hand it a task from one of your users. It will read the source of the modules you expose, write a Lua (or Elixir) snippet, run it in a sandbox, look at the result, and write the next one - until the task is done.

One evaluation can filter, branch, and loop - work that would cost a tool-calling agent an LLM round trip per step ([Anthropic on why code execution beats tool calling](https://www.anthropic.com/engineering/code-execution-with-mcp)).

## Usage

1. Add Legion to your `mix.exs`:

```elixir
def deps do
  [
    {:legion, "~> 0.4"}
  ]
end
```

2. Configure an LLM provider ([all options](https://hexdocs.pm/req_llm/ReqLLM.html#module-configuration)):

```elixir
# config/runtime.exs
config :req_llm, openai_api_key: System.get_env("OPENAI_API_KEY")
```

3. Expose existing or new modules as tools and hand them to an agent:
```elixir
defmodule MyApp.Tools.ScraperTool do
  use Legion.Tool

  @doc "Fetches recent posts from HackerNews"
  def fetch_posts do
    Req.get!("https://hn.algolia.com/api/v1/search_by_date").body["hits"]
  end
end

defmodule MyApp.Tools.DatabaseTool do
  use Legion.Tool

  @doc "Saves a post title to the database"
  def insert_post(title), do: Repo.insert!(%Post{title: title})
end

defmodule MyApp.ResearchAgent do
  @moduledoc "Fetch posts, evaluate their relevance and quality, and save the good ones."
  use Legion.Agent

  def tools, do: [MyApp.Tools.ScraperTool, MyApp.Tools.DatabaseTool]
end
```

4. Run it!
```elixir
Legion.execute(MyApp.ResearchAgent, "Find cool Elixir posts about Advent of Code and save them")
#=> {:ok, "Found 3 relevant posts and saved 2 that met quality criteria."}
```

To solve this task, the agent wrote and ran:

```elixir
ScraperTool.fetch_posts()
|> Enum.filter(fn post ->
  title = String.downcase(post["title"] || "")
  String.contains?(title, "elixir") and String.contains?(title, "advent")
end)
```

...looked at the output, judged which posts were worth keeping, and followed up with:

```elixir
["Elixir Advent of Code 2024 - Day 5 walkthrough", "My first AoC in Elixir!"]
|> Enum.each(&DatabaseTool.insert_post/1)
```

Two evaluations, with `Enum`, pattern matching, and pipelines available at every step. A tool-calling agent would have paid a round trip for every filter decision and every insert. The generated code is disposable, like a shell one-liner: written to do one thing, right now, then thrown away. Legion is a runtime, not a coding assistant.

## Features

### **1. Tools are plain Elixir modules**

`use Legion.Tool` on any module and the LLM reads its source and calls its public functions. Third-party modules work too, without a wrapper:

   ```elixir
   # config/config.exs
   config :legion, extra_source_modules: [Req, Jason]

   defmodule MyApp.APIAgent do
     @moduledoc "Fetches data from JSON APIs and decodes responses."
     use Legion.Agent

     def tools, do: [Req, Jason]
   end
   ```

   Use it to hand agents your existing app logic directly - no schemas to write, nothing to keep in sync. With great power comes great responsibility (and authorization): the agent can call any public function of a tool, so scope tools to what it should touch and gate the sensitive parts with [Vault](https://github.com/dimamik/vault) (see [Credentials never reach the LLM](#7-credentials-never-reach-the-llm)). For large libraries, write a thin facade with `defdelegate` and a `description/0` instead of exposing the full source.

   See [`Legion.Tool`](https://hexdocs.pm/legion/Legion.Tool.html) for more details.

### **2. Agents are BEAM processes** 

Start one, keep it around, and message it like a GenServer.

   ```elixir
   {:ok, pid} = Legion.start_link(MyApp.AssistantAgent)

   {:ok, response} = Legion.call(pid, "Find laptops under $2000")
   {:ok, response} = Legion.call(pid, "Now filter for 16GB of RAM")
   Legion.cast(pid, "Also check the reviews")
   ```

   Use it when a conversation spans multiple messages - variables can even persist between turns with `binding_scope: :conversation`. And since agents are just processes, supervision trees and `:pg`-based pools work out of the box:

   ```elixir
   for _ <- 1..5 do
     {:ok, pid} = Legion.start_link(SupportAgent)
     :pg.join(:support_pool, pid)
   end

   agent = :pg.get_members(:support_pool) |> Enum.random()
   Legion.cast(agent, "Handle this support ticket: #{ticket}")
   ```

   See [`start_link/2`](https://hexdocs.pm/legion/Legion.html#start_link/2), [`call/3`](https://hexdocs.pm/legion/Legion.html#call/3), and [`cast/2`](https://hexdocs.pm/legion/Legion.html#cast/2) for more details.

### **3. Generated code runs in a sandbox**

Every evaluation runs in a monitored process with timeout, memory, and CPU budgets. Two sandboxes ship with Legion, differing in language and trust model:
   - [`Legion.Sandbox.Lua`](https://hexdocs.pm/legion/Legion.Sandbox.Lua.html) (default) - agents write Lua, evaluated by [lua](https://hexdocs.pm/lua), a Lua 5.3 VM in pure Elixir. Lua code cannot reach the host BEAM at all - the only bridges out are the tool functions Legion registers - making it the safer choice for less trusted generation.
   - [`Legion.Sandbox.Elixir`](https://hexdocs.pm/legion/Legion.Sandbox.Elixir.html) - agents write Elixir. Dangerous constructs (`defmodule`, `import`, `spawn`, `send`, `apply`, ...) are blocked at the AST level and module access is allowlisted (stdlib + your tools). Powerful, but the allowlist guards an enormous language surface - use it for your own LLM-backed agents with controlled tool access, not arbitrary code from unknown sources.

   Neither is OS-level isolation - evaluation still runs inside your BEAM VM. If your threat model requires that, run agents in a separate BEAM instance. Custom sandboxes (for example, executing in the user's browser via [popcorn](https://github.com/software-mansion/popcorn/)) implement the [`Legion.Sandbox`](https://hexdocs.pm/legion/Legion.Sandbox.html) behaviour.

### **4. Agents orchestrate agents**

Give an agent the built-in `AgentTool` and its generated code can delegate.

   ```elixir
   defmodule MyApp.OrchestratorAgent do
     @moduledoc "Coordinates research and writing sub-agents to produce finished content."
     use Legion.Agent

     def tools, do: [Legion.Tools.AgentTool]
     def tool_config(Legion.Tools.AgentTool), do: [agents: [MyApp.ResearchAgent, MyApp.WriterAgent]]
   end
   ```

The orchestrator writes code like:

   ```elixir
   {:ok, research} = AgentTool.call(MyApp.ResearchAgent, "Find info about Elixir 1.18")
   {:ok, draft} = AgentTool.call(MyApp.WriterAgent, "Write a blog post using: #{research}")
   ```

   Sub-agents are linked processes - when a parent dies, its children stop too. From the outside, fan out with [`parallel/2`](https://hexdocs.pm/legion/Legion.html#parallel/2) or chain with [`pipeline/1`](https://hexdocs.pm/legion/Legion.html#pipeline/1):

   ```elixir
   {:ok, [posts, trends]} = Legion.parallel([
     {MyApp.ResearchAgent, "Find recent Elixir posts"},
     {MyApp.AnalysisAgent, "Summarize Elixir trends"}
   ])

   {:ok, result} = Legion.pipeline([
     {MyApp.ResearchAgent, "Find Elixir blog posts from this week"},
     {MyApp.WriterAgent, &"Summarize these posts: #{&1}"}
   ])
   ```

   See [`Legion.Tools.AgentTool`](https://hexdocs.pm/legion/Legion.Tools.AgentTool.html) for more details.

### **5. Conversations survive restarts**

Plug in the Postgres store (it can reuse your Ecto repo) and resume any conversation by id, even after a deploy.

   ```elixir
   defmodule MyApp.AgentStore do
     use Legion.Store.Postgres, repo: MyApp.Repo
   end

   {:ok, pid} =
     Legion.start_link(MyApp.AssistantAgent,
       store: MyApp.AgentStore,
       agent_id: "user_42:chat_7"
     )

   {:ok, response} = Legion.call(pid, "Remember that my budget is $100")

   # Later, after the original process has stopped
   {:ok, pid} = Legion.resume("user_42:chat_7", store: MyApp.AgentStore)
   ```

   Create the table with `Legion.Store.Migration.Postgres.up()` in a migration. Stores persist at turn boundaries by default; pass `persistence_frequency: :step` to also checkpoint intermediate results and recoverable errors. Use `Legion.Store` to implement any other storage.

   See [`Legion.Store`](https://hexdocs.pm/legion/Legion.Store.html) for more details.

### **6. Humans stay in the loop**

The built-in `HumanTool` pauses execution and sends the question to your handler process. It's just message passing - the handler receives `{:human_request, ref, from_pid, question, meta}` and replies with `{:human_response, ref, answer}`.

   ```elixir
   defmodule MyApp.AssistantAgent do
     @moduledoc "An assistant that can ask the user questions."
     use Legion.Agent

     def tools, do: [Legion.Tools.HumanTool]
     def tool_config(Legion.Tools.HumanTool), do: [handler: MyApp.ChatHandler, timeout: 30_000]
   end
   ```

   Use it for approvals and clarifying questions mid-task.

   See [`Legion.Tools.HumanTool`](https://hexdocs.pm/legion/Legion.Tools.HumanTool.html) for more details.

### **7. Credentials never reach the LLM** 

Set auth context before the agent starts, read it inside tools at runtime via [Vault](https://github.com/dimamik/vault). Generated code has no access to it.

   ```elixir
   Vault.init(current_user: %{id: user.id})
   {:ok, result} = Legion.execute(MyApp.PostsAgent, "Find my posts from today and summarize them")
   ```

   ```elixir
   defmodule MyApp.Tools.PostsTool do
     use Legion.Tool

     def get_my_posts do
       %{id: user_id} = Vault.get(:current_user)
       Repo.all(from p in Post, where: p.user_id == ^user_id)
     end
   end
   ```

   See [Vault](https://github.com/dimamik/vault) for more details.

### **8. Structured output when you need it**

Define `output_schema/0` on the agent to get typed, validated responses instead of prose. Skip it and you get plain text.

   See [`Legion.Agent`](https://hexdocs.pm/legion/Legion.Agent.html) for this and the other agent callbacks (`system_prompt/0`, `config/0`, `action_types/0`) - all optional with sensible defaults.


## Configuration

```elixir
config :legion, :store, MyApp.AgentStore

config :legion, :config, %{
  model: "openai:gpt-5.4",
  max_iterations: 10,
  max_retries: 3,
  sandbox_timeout: 60_000,
  binding_scope: :turn,
  max_message_length: 20_000
}
```

| Option               | Description                                                                                                                |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `model`              | LLM model string passed to [ReqLLM](https://hexdocs.pm/req_llm), e.g. `"openai:gpt-5.4"`.                                  |
| `max_iterations`     | Successful execution steps before the agent is stopped.                                                                    |
| `max_retries`        | Consecutive failures (bad code, tool errors) before giving up. Resets after each success.                                  |
| `sandbox`            | Sandbox module evaluating generated code: `Legion.Sandbox.Lua` (default) or `Legion.Sandbox.Elixir`. See [Sandboxing](#sandboxing). |
| `sandbox_timeout`    | Milliseconds a single code evaluation may run before it is killed.                                                         |
| `binding_scope`      | `:iteration` (fresh each step), `:turn` (persist within a message, default), or `:conversation` (persist across messages). |
| `max_message_length` | Byte limit for any single message. Longer content is truncated. Set to `:infinity` to disable.                             |

Agents override global config by defining `config/0`:

```elixir
defmodule MyApp.DataAgent do
  @moduledoc "Fetches and processes data from HTTP APIs."
  use Legion.Agent

  def tools, do: [MyApp.HTTPTool]
  def config, do: %{model: "anthropic:claude-sonnet-4-20250514", max_iterations: 5}
end
```

Writing code is the one thing models keep getting better at - update the `model` string and every agent in your app gets smarter, for free.

## Telemetry

```elixir
Legion.Telemetry.attach_default_logger()
```

Events emitted at every level:

- `[:legion, :agent, :started | :stopped]` - agent lifecycle
- `[:legion, :agent, :message, :start | :stop | :exception]` - per-message
- `[:legion, :iteration, :start | :stop | :exception]` - each execution step
- `[:legion, :llm, :request, :start | :stop | :exception]` - LLM API calls
- `[:legion, :sandbox, :eval, :start | :stop | :exception]` - code evaluation

## Limitations

### Sandboxing

Sandboxes are pluggable via the `sandbox` config key. Both built-in sandboxes run evaluations in a monitored process with timeout, memory, and CPU budgets (`sandbox_timeout`, `sandbox_max_heap`, `sandbox_max_reductions`); they differ in language and trust model:

- **`Legion.Sandbox.Lua`** (default) - agents write Lua, evaluated by [lua](https://hexdocs.pm/lua), a Lua 5.3 VM implemented in pure Elixir. Lua code has no way to reach the host BEAM at all - the only bridges out of the VM are the tool functions Legion registers - which makes it the safer choice when the generated code is less trusted. Tool arguments and results are converted at the boundary (Lua tables to maps/lists and back; Elixir tuples become arrays, atoms become strings).
- **`Legion.Sandbox.Elixir`** - agents write Elixir. Dangerous constructs (`defmodule`, `import`, `spawn`, `send`, `apply`, ...) are blocked at the AST level and module access is limited to an allowlist (stdlib + your tools). Powerful - tools are plain Elixir calls - but the allowlist guards an enormous language surface, and new escape vectors could be found. Use it for trusted code generators (your own LLM-backed agents with controlled tool access), not arbitrary code from unknown sources.

Neither sandbox is full OS-level isolation - evaluation still runs inside your BEAM VM. If your threat model requires that, run agents in a separate BEAM instance.

Custom sandboxes implement the `Legion.Sandbox` behaviour.


## Web Dashboard

[`legion_web`](https://github.com/software-mansion-labs/legion_web) provides a real-time Phoenix LiveView dashboard for monitoring agents, viewing conversation traces, and inspecting generated code.

![Legion Web Dashboard](https://raw.githubusercontent.com/software-mansion-labs/legion_web/main/img/preview.png)

<!-- MDOC -->

## Authors

Legion is created by Software Mansion.

Since 2012 [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=legion) is a software agency with experience in building web and mobile apps as well as complex multimedia solutions. We are Core React Native Contributors, Elixir ecosystem experts, and live streaming and broadcasting technologies specialists. We can help you build your next dream product – [Hire us](https://swmansion.com/contact/projects).

Copyright 2026, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=legion)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=legion-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=legion)

## License

MIT License - see [LICENSE](LICENSE) for details.
