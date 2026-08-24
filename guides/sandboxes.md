# Sandboxes

Legion evaluates LLM-generated code through a pluggable sandbox, selected with
the `sandbox` config key:

```elixir
# globally
config :legion, :config, %{sandbox: Legion.Sandbox.Lua}

# or per agent, which wins over the global setting
def config, do: %{sandbox: Legion.Sandbox.Lua}
```

Three implementations ship with Legion: `Legion.Sandbox.Lua` (the default),
`Legion.Sandbox.Elixir`, and `Legion.Sandbox.Popcorn`. Custom sandboxes
implement the `Legion.Sandbox` behaviour. All three run under
`Legion.Sandbox.Runner`, so the operational limits (`sandbox_timeout`,
`sandbox_max_heap`, `sandbox_max_reductions`, `sandbox_priority`) are
configured the same way - they mean the same thing for the two sandboxes
that evaluate inside your VM, and something narrower for the one that
evaluates in the visitor's browser (see [Running on the visitor's
hardware](#running-on-the-visitor-s-hardware)).

## The core difference: where the security boundary sits

**`Legion.Sandbox.Elixir`** - generated code *is* host code. `Code.eval_string/2`
runs it on the BEAM with full language power, and safety comes from the AST
checker rejecting dangerous forms before evaluation. The boundary is a
deny-by-default allowlist over the entire Elixir surface - every module,
function, arity, struct literal, and sigil the stdlib offers is a potential
escape hatch that has to be reasoned about. The checker is hardened against
the known RCE classes, but it is structurally a cat-and-mouse game.

**`Legion.Sandbox.Lua`** - generated code runs inside
[lua](https://hexdocs.pm/lua), a Lua 5.3 VM implemented in pure Elixir. Lua code has no representation for anything on the host: it cannot
name a module, build an atom, touch a process, or force-load anything. The
only doors out of the VM are the tool functions Legion explicitly bridges in.
The residual attack surface is your tools plus bugs in the VM. This makes it the safer choice for less trusted code.

**`Legion.Sandbox.Popcorn`** - generated code never runs on your BEAM at
all. It is Elixir again, but each evaluation is relayed to the visitor's
browser and runs there, on a small Elixir VM - AtomVM compiled to
WebAssembly via [popcorn](https://popcorn.hexdocs.pm). The boundary is
neither an allowlist nor a VM inside your VM: it is the visitor's tab. An
escape lands in a page the visitor already controls, not in your
application. What stays on the server is the tool RPC - the relay accepts
only calls naming a registered tool's public function with a matching
arity - so your tools are the entire server-side attack surface.

A useful side effect of the two non-host sandboxes: Lua code cannot create
atoms at all (identifiers and strings stay binaries inside the VM), and
whatever atoms browser-side code creates live in the visitor's VM - the
relay never turns incoming strings into atoms beyond looking up registered
tool function names with `String.to_existing_atom/1`. The atom-table-growth
DoS vector the Elixir sandbox documents as unsolved does not exist in
either.

## What the model can do inside

| | `Legion.Sandbox.Elixir` | `Legion.Sandbox.Lua` | `Legion.Sandbox.Popcorn` |
|---|---|---|---|
| Language | Elixir minus denied forms | Lua 5.3 semantics | Elixir, no denied forms, on AtomVM |
| Stdlib | Allowlisted `Enum`, `String`, `Map`, `Date`/`DateTime`, `Regex`, `JSON`, `URI`, `:math`, ... | Lua's `string`, `table`, `math`; `os.time`/`os.date` (`io`, `file`, `os.getenv`/`os.execute`, `require`, `load`, `print` are blocked) | `Kernel`, `Enum`, `String`, `Map`, `List`, `Integer`; many modules missing or partial (`:ets`, `:timer`, `:rand`, `File`, `System`, `Regex`, big integers) |
| Regex | Full `Regex` / PCRE | Lua patterns only (`string.match`) - weaker | Not available |
| JSON | Built-in `JSON` module | None - expose a tool if agents need it | None - expose a tool if agents need it |
| Dates | Rich calendar modules | `os.date` / `os.time` only | Partial - prefer tools |
| State between executions | All bindings persist | Only **globals** persist; `local`s vanish per chunk | All bindings persist, per browser session, until the page reloads |
| Result | Last expression | Explicit `return` required | Last expression |

## The bridge, and what gets lost crossing it

Tools are Elixir; in the Lua and Popcorn sandboxes the model calls them from
another VM. Every call crosses an encode/decode boundary - Lua tables on one
side, JSON over the network on the other - and that boundary is lossy in
both directions:

- **Tools receive string-keyed maps.** `{date = "..."}` in Lua, or
  `%{date: "..."}` written in the browser, arrives as `%{"date" => ...}`,
  never `%{date: ...}`. A tool that pattern-matches atom keys works in the
  Elixir sandbox and breaks in both others. This is the single most likely
  thing to bite when reusing existing tools.
- **Tuples do not exist in Lua or JSON.** Results like `{:ok, 42}` arrive as
  the array `["ok", 42]`; tuple-taking APIs receive 2-element lists.
  `Legion.Tools.AgentTool.parallel/2` and `pipeline/1` normalise
  `[agent, task]` pairs, but any other tuple-shaped tool API needs the same
  treatment or a bridge-friendly facade.
- **Atoms become strings, structs become plain field tables/maps** (module
  identity dropped - and the flattening is `Map.from_struct/1`, so internal
  fields like a `Date`'s `calendar` cross too; project the fields the model
  needs in the tool if that matters). Anything the Lua VM cannot encode -
  pids, refs, or a function value that is not `fun(args)` /
  `fun(args, state)` - is a runtime error fed back to the model (that arity
  limit is on the Elixir closure itself; `args` is one list, so Lua-side
  argument count is unbounded). The Popcorn bridge instead `inspect/1`s
  such values into strings.
- **The empty Lua table is ambiguous**: it decodes as `[]`, so a tool cannot
  tell "empty list" from "empty map". JSON keeps `[]` and `{}` apart.
- **Module references** work only for bridged tools: passing a tool's Lua
  global table, or its stub module in the browser, where an Elixir module
  is expected (`AgentTool.call(PlannerAgent, task)`) resolves to the module
  atom. There is no general way to name an arbitrary Elixir module - which
  is a feature.
- **Only `use Legion.Tool` modules expose functions.** Anything else in the
  list (sub-agent modules, extra allowed modules) is bridged reference-only:
  a table or stub carrying just the module marker, with no callable
  functions.
- **Tool docs are Elixir source.** The Lua model must translate signatures;
  models handle this well, but hand-written `description/1` overrides with
  Lua examples help for complex tools. The Popcorn model reads them as-is
  and calls tools by their short module name (`Canvas.show/1`, not
  `MyApp.Tools.Canvas.show/1`).
- **In the browser, every tool call is a network round trip.** Batching
  work into few calls matters far more than in-VM; the prompt constraints
  tell the model so.

## Chaining tools

A struct one tool returns crosses the bridge as a string-keyed field table
or map and can only come back as a plain map - `def associate(%Post{} = post, _)`
never matches again, and no model retry can fix it, because neither Lua nor
the browser VM can construct your struct. Chains that pass rich values
between tools need one of these shapes:

- **Plain maps chain as-is.** Tools that accept the string-keyed maps they
  emit compose freely; the model can filter and reshape between calls.
- **Pass ids** (the default): tools exchange identifiers and refetch
  internally, so the sandbox only ever holds scalars.
- **Rehydrate at the boundary**: the tool accepts the map and rebuilds its
  struct inside - a few lines that double as input validation - for when the
  model must inspect or transform payload fields in the sandbox.
- **Opaque handles**: park the value host-side (an ETS table scoped per
  conversation, or the store) and return a token plus the fields the model
  may read; later tools resolve the token back to the exact original term.
  The only option for values the bridge cannot encode at all - pids, refs,
  connections. Handles outlive a single eval, so give them a lifecycle:
  scope by conversation, clean up when it ends, and answer a stale token
  with an error message the model can react to.

## Performance and limits

All sandboxes run under the same `Legion.Sandbox.Runner` (timeout,
`max_heap` plus off-heap binary polling, `max_reductions`, priority). For
the two in-VM sandboxes the limits bound the evaluation itself. But the Lua
VM interprets on the BEAM - the same computation costs roughly one to two
orders of magnitude more time and reductions than native Elixir. Budgets
tuned for the Elixir sandbox (especially `sandbox_max_reductions`) may need
raising, and heavy in-sandbox data crunching is better pushed into tools.

The Lua sandbox adds one deterministic guard of its own: the VM refuses to
build any single string larger than half the `max_heap` budget, so a string
bomb comes back as a catchable "resulting string too large" error instead of
racing the heap kill mid-allocation.

Bindings are also heavier: persisting them means serialising the whole Lua
VM state, not a small keyword list - worth remembering with
`binding_scope: :conversation` and a database-backed store. The VM has no
state garbage collector yet, so dead tables from each evaluation stay in
that state for the life of the conversation.

The browser sandbox spends your server's budget only on the relay, and the
visitor's on everything else - see the next section.

## What the in-VM sandboxes do not give you

`Legion.Sandbox.Elixir` and `Legion.Sandbox.Lua` still execute inside your
application's VM: tool code runs with full host privileges, scheduler time
is shared, and memory is consumed until limits kill the eval. The Lua
sandbox removes the *language-level* escape routes, not the blast radius of
a badly designed tool - `AgentTool`, HTTP tools, and DB tools are exactly as
dangerous as what you expose through them. Full isolation would mean a
separate BEAM instance, which undermines the concept of Legion's shared
resources and easily accessible (and thus powerful) tools.

`Legion.Sandbox.Popcorn` is the one that changes this equation: the
separate VM is the visitor's browser, and the shared resources stay
reachable through the tool bridge.

## Running on the visitor's hardware

With `Legion.Sandbox.Popcorn`, `execute/5` hands the code to the browser
session registered for the agent and blocks until the browser returns the
result, serving the code's tool calls in the meantime. Tool calls run on
your server, in the relay process, with Vault context and telemetry like
the other sandboxes; the generated code itself never touches your BEAM.

It needs more wiring than the in-VM sandboxes:

- **The agent must have an `:agent_id`** - evaluations are routed by it.
- **The consuming application runs `{Legion, []}` in its supervision tree**,
  which starts the `Legion.Sandbox.Popcorn.Host` registry, and bridges a
  browser session to it - typically a Phoenix Channel that registers itself
  for the agent's id and forwards the eval and tool-call messages between
  the sandbox and the page. The message protocol is documented in
  `Legion.Sandbox.Popcorn`.
- **The application serves `priv/popcorn`** - the cooked `.avm` bundle plus
  the popcorn JS/WASM runtime the page loads. The hex package ships them;
  a git or path checkout builds them from `popcorn_client/` (see its
  README - it needs the toolchain popcorn pins).
- **The page must be cross-origin isolated.** The runtime uses
  `SharedArrayBuffer`, so the document that loads it must be served with
  `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Embedder-Policy: require-corp` - which in turn blocks
  cross-origin resources that do not opt in via CORS/CORP. Plan the page's
  images and scripts accordingly.

Bindings live browser-side. The `bindings` term threaded through the
executor is just a descriptor - `%{session_id, binding_names}` - while the
variable values sit in the browser evaluator. The descriptor is small and
serialisable, so checkpointing works, but a checkpoint persists only the
descriptor: if the visitor reloads the page, the values are gone and the
model recovers through undefined-variable errors. Do not expect
`binding_scope: :conversation` to give durable state here.

The operational limits read differently, too. The relay runs under
`Legion.Sandbox.Runner`, so `sandbox_timeout` bounds the whole evaluation -
including the wait for a browser host to connect at all (no tab open means
the eval blocks until the timeout kills it). But `sandbox_max_heap` and
`sandbox_max_reductions` bound only the server-side relay and the tool
execution it performs; they cannot reach into the browser VM. A runaway
loop in generated code burns the visitor's CPU until the timeout, not your
server's. One tab evaluates one thing at a time: a second eval arriving
while one runs is rejected as busy.

**Rule of thumb:** use `Legion.Sandbox.Elixir` for trusted generators that
need rich data manipulation; use `Legion.Sandbox.Lua` when the code is less
trusted or the tool surface is small and well-defined - and design tools for
Lua consumption (string keys in, no tuples out); use `Legion.Sandbox.Popcorn`
when the evaluation belongs on the visitor's machine - it takes a connected
browser tab per agent, and leaves only your tools exposed on the server.
