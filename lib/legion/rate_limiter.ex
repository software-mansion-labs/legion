defmodule Legion.RateLimiter do
  @moduledoc """
  Behaviour for enforcing rate limits across Legion agents.

  A rate limiter decides whether an agent may proceed under a `Policy`. Call
  `enforce!/3` at the point where work should be admitted, passing the agent's
  stable id, a map that identifies its cohort, and the policy to apply:

      :ok = MyApp.RateLimiter.enforce!(agent_id, %{provider: "openai"}, policy)

  The behaviour is the seam for custom rate-limiter adapters. The bundled
  `Legion.RateLimiter.Postgres` adapter records cohort metadata and evaluates
  policies from the same Postgres table used by `Legion.Store.Postgres`.

  ## Implementing a rate limiter

  Define a module that implements `enforce!/3` when rate-limit state lives
  outside Postgres or needs application-specific coordination:

      defmodule MyApp.RateLimiter do
        @behaviour Legion.RateLimiter

        @impl Legion.RateLimiter
        def enforce!(agent_id, key, policy) do
          # Check and record the rate-limit state for this adapter.
          :ok
        end
      end

  See `Legion.RateLimiter.Policy` for the available limits and
  `Legion.RateLimiter.Postgres` for the ready-made Postgres adapter.
  """
  alias Legion.RateLimiter.Policy
  alias Legion.Store

  @type limit_key :: %{String.t() => any()}

  @doc """
  Enforces `policy` for agents matching `key`.

  Returns `:ok` when the adapter admits the agent. The adapter defines how
  keys match and how it stores rate-limit state.

  Raises `Legion.RateLimiter.ExceededError` when any configured limit has
  been reached.
  """
  @callback enforce!(agent_id :: Store.agent_id(), key :: limit_key(), policy :: Policy.t()) ::
              :ok | no_return()
end
