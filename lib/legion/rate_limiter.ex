defmodule Legion.RateLimiter do
  @moduledoc """
  Behaviour for enforcing rate limits across Legion agents.

  A rate limiter decides whether an agent may proceed under a `Policy`. Legion
  calls `enforce!/3` for you: configure a limiter, a policy, and an identity, and
  every turn is admitted through it.

      Legion.start_link(ChatAgent,
        rate_limit: [
          limiter: MyApp.RateLimiter,
          policy: %Legion.RateLimiter.Policy{
            interval_ms: :timer.minutes(1),
            max_agents: 10,
            max_tokens: 100_000
          },
          identity: %{"ip" => "203.0.113.42"}
        ]
      )

  Configure the same values globally to apply the policy to every matching
  agent:

      config :legion, :rate_limit,
        limiter: MyApp.RateLimiter,
        policy: policy,
        identity: %{"ip" => "203.0.113.42"}

  All three must be present for a limit to apply; leaving any of them `nil`
  disables rate limiting. An `identity` identifies the shared cohort: agents with
  matching identities consume the same rolling-window limits. Each field in
  `:rate_limit` given to `Legion.start_link/2` wins over the application
  environment, and sub-agents inherit whatever their parent resolved unless
  given their own. Each sub-agent is a separate agent ID in the cohort, so it
  counts towards `:max_agents` and its usage towards `:max_tokens`.

  ## When Legion enforces

  Enforcement happens once per turn, before the incoming message is appended
  and before any LLM request. A refusal therefore leaves the conversation
  untouched and costs nothing.

  Refused turns return `{:cancel, {:rate_limited, violations}}` - the same
  shape as `{:cancel, :reached_max_iterations}` - so a refused sub-agent
  reports back to its caller as a value rather than a crash. Legion also emits
  `[:legion, :rate_limit, :exceeded]`; see `Legion.Telemetry`.

  Resumed and recovered runs are *not* re-admitted. They are finishing work
  that was already admitted, so re-checking them would discard accepted work
  instead of shedding new load.

  ## Calling it yourself

  `enforce!/3` is public, so an application can also admit its own work under
  the same policy - a webhook, a queue worker - by passing a stable id, a map
  that identifies the shared cohort, and the policy:

      :ok = MyApp.RateLimiter.enforce!(agent_id, %{"ip" => "203.0.113.42"}, policy)

  The behaviour is the seam for custom rate-limiter adapters. The bundled
  `Legion.RateLimiter.Postgres` adapter records cohort metadata and evaluates
  policies from the same Postgres table used by `Legion.Store.Postgres`.

  ## Implementing a rate limiter

  Define a module that implements `enforce!/3` when rate-limit state lives
  outside Postgres or needs application-specific coordination:

      defmodule MyApp.RateLimiter do
        @behaviour Legion.RateLimiter

        @impl Legion.RateLimiter
        def enforce!(agent_id, identity, policy) do
          # Check and record the rate-limit state for this adapter.
          :ok
        end
      end

  See `Legion.RateLimiter.Policy` for the available limits and
  `Legion.RateLimiter.Postgres` for the ready-made Postgres adapter.
  """
  alias Legion.RateLimiter.Policy
  alias Legion.Store

  @type limit_identity :: %{String.t() => any()}

  @doc """
  Enforces `policy` for agents with a given `identity`.

  Returns `:ok` when the adapter admits the agent. The adapter defines how
  identities match and how it stores rate-limit state.

  Raises `Legion.RateLimiter.ExceededError` when any configured limit has
  been reached. Legion catches that exception and cancels the turn; any other
  error propagates, so an adapter that cannot reach its backing store fails
  the agent rather than silently admitting it.
  """
  @callback enforce!(agent_id :: Store.agent_id(), identity :: limit_identity(), policy :: Policy.t()) ::
              :ok | no_return()
end
