defmodule Legion.Sandbox do
  @moduledoc """
  Behaviour for sandboxes that evaluate LLM-generated code.

  A sandbox owns everything language-specific about code execution: static
  validation, evaluation, how variable state persists between executions, and
  the language-specific sections of the agent system prompt.

  Built-in implementations:

    - `Legion.Sandbox.Lua` (default) — evaluates Lua via
      [lua](https://hexdocs.pm/lua), a Lua 5.3 VM written in pure Elixir.
      Nothing in the Lua world can touch the host BEAM except the tool
      functions you explicitly bridge in, which makes it the safer choice for
      less trusted code.
    - `Legion.Sandbox.Elixir` — evaluates Elixir with AST-level allowlist
      checking. Powerful (tools are plain Elixir calls) but the allowlist is a
      blocklist-shaped problem: new RCE vectors in the huge Elixir surface are
      found regularly.

  Select per agent (or globally) with the `:sandbox` config key:

      def config, do: %{sandbox: Legion.Sandbox.Elixir}

  Both built-ins evaluate inside `Legion.Sandbox.Runner`, which enforces the
  timeout, memory, and CPU limits regardless of language. Nothing above
  `c:execute/5` enforces them, so a custom sandbox should wrap its evaluation
  in `Legion.Sandbox.Runner.run/3` too - otherwise the `timeout_ms` and
  `limits` it is handed have no effect.

  ## Bindings

  `bindings` is an opaque, serialisable term owned by the sandbox: a keyword
  list for `Legion.Sandbox.Elixir`, a list of `{name, value}` pairs of user
  globals for `Legion.Sandbox.Lua`.
  `[]` always means "fresh state". The executor threads it between
  executions and persists it in checkpoints without inspecting it beyond
  `c:binding_names/1`.
  """

  @doc """
  Static validation of `code` before execution (and before any `EvalGuard`).

  Return `:ok` when the sandbox has no meaningful static check — errors then
  surface from `c:execute/5` instead.
  """
  @callback check(code :: String.t(), tools :: [module()]) :: :ok | {:error, term()}

  @doc """
  Evaluates `code` with the given tools, bindings, and limits.

  Returns `{:ok, {value, new_bindings}}` or `{:error, reason}`.

  Enforcing `timeout_ms` and `limits` is the implementation's job: run the
  evaluation through `Legion.Sandbox.Runner.run/3`, which is where that
  contract lives.
  """
  @callback execute(
              code :: String.t(),
              timeout_ms :: non_neg_integer() | :infinity,
              tools :: [module()],
              bindings :: term(),
              limits :: keyword()
            ) :: {:ok, {term(), term()}} | {:error, term()}

  @doc """
  Names of user-defined variables in `bindings`, shown to the LLM after each
  execution.
  """
  @callback binding_names(bindings :: term()) :: [atom() | String.t()]

  @doc """
  Language-specific system prompt sections:

    - `:language` — name shown to the LLM, e.g. `"Elixir 1.18.4"`.
    - `:constraints` — markdown bullet list of language / sandbox rules.
    - `:tool_usage` — one-line explanation of how to call tools from code.
  """
  @callback prompt_info() :: %{
              language: String.t(),
              constraints: String.t(),
              tool_usage: String.t()
            }
end
