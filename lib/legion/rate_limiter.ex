defmodule Legion.RateLimiter do
  @moduledoc """
  Behaviour for enforcing rate limits across Legion agents.

  A rate limiter decides whether an agent may proceed under a list of
  `Legion.RateLimiter.Rule`s. Each rule pairs an identity - the group of
  agents sharing a limit - with a `Legion.RateLimiter.Policy`. Legion calls
  `enforce!/2` for you: configure a limiter and rules, and every turn is
  checked against them.

      Legion.start_link(ChatAgent,
        rate_limit: [
          limiter: MyApp.RateLimiter,
          rules: [
            %Legion.RateLimiter.Rule{
              identity: %{"ip" => "203.0.113.42", "tenant" => "acme"},
              policy: %Legion.RateLimiter.Policy{
                window_ms: :timer.minutes(30),
                max_agents: 40,
                max_tokens: 200_000
              }
            },
            %Legion.RateLimiter.Rule{
              identity: %{"email" => "someone@example.com"},
              policy: %Legion.RateLimiter.Policy{window_ms: :timer.hours(24), max_agents: 5}
            }
          ]
        ]
      )

  A turn runs only if every rule allows it; the first rule that denies it
  cancels the turn. Rules are evaluated in the order given, so put the rule
  whose denial you want reported first.

  For Postgres users there is a ready-made adapter - see
  `Legion.RateLimiter.Postgres`. It extends `Legion.Store.Postgres`, keeping
  rate-limit metadata in the store's table and counting the usage persisted
  there:

      defmodule MyApp.RateLimiter do
        use Legion.RateLimiter.Postgres, repo: MyApp.Repo
      end

  ## Configuration

  The limiter and a default policy are usually set once, globally, leaving
  only the identities to the call site:

      config :legion, :rate_limit,
        limiter: MyApp.RateLimiter,
        default_policy: %Legion.RateLimiter.Policy{window_ms: :timer.minutes(1), max_agents: 10}

      Legion.start_link(ChatAgent,
        rate_limit: [rules: [%Legion.RateLimiter.Rule{identity: %{"ip" => "203.0.113.42"}}]]
      )

  A rule given without a `:policy` takes the default one. Rules can be
  configured globally too, as a cap on every agent started without a
  `:rate_limit` of its own:

      config :legion, :rate_limit,
        limiter: MyApp.RateLimiter,
        rules: [%Legion.RateLimiter.Rule{identity: %{}, policy: policy}]

  An agent's rate limit is resolved once, when it starts: its `:rate_limit`
  option if given, else the parent agent's rate limit, else the application
  config. Whichever applies is taken as a whole - rules are never merged
  across the three - with only a missing `:limiter` or rule `:policy` filled
  from the application config. Rate limiting applies only when a limiter and at
  least one rule resolve; a limiter without rules, or rules without a limiter,
  disables it. A sub-agent inherits its parent's rate limit, so a parent
  started with `rate_limit: [rules: []]` runs its whole subtree without one,
  even when the application configures rules globally. Each sub-agent is a
  separate agent ID in every group, so it counts towards `:max_agents` and its
  usage towards `:max_tokens`.

  Rules must agree on their identities: two rules may share a field only with
  the same value, since the adapter records one group membership per agent.
  Two rules with the same identity and different policies are fine - for
  example a per-minute and a per-day window on one IP. Identity keys must be
  strings; an empty identity `%{}` matches every agent and acts as a global cap.

  ## When Legion enforces

  Enforcement happens once per turn, before the incoming message is appended
  and before any LLM request. A denial therefore leaves the conversation
  untouched and costs nothing.

  Denied turns return `{:cancel, {:rate_limited, violations}}` - the same
  shape as `{:cancel, :reached_max_iterations}` - so a denied sub-agent
  reports back to its caller as a value rather than a crash. Legion also emits
  `[:legion, :rate_limit, :exceeded]` with the identity and policy of the rule
  that denied it; see `Legion.Telemetry`.

  Resumed and recovered runs are *not* checked again. They are finishing work
  that was already allowed, so checking it again would discard accepted work
  instead of shedding new load.

  ## Calling it yourself

  `resolve!/1` and `enforce!/2` are public, so an application can rate-limit its
  own work - a webhook, a queue worker - under the same configuration as
  agents. Resolve the configured limiter and rules, which fills in the
  default policy, then enforce them under a stable id:

      %{limiter: limiter, rules: rules} =
        Legion.RateLimiter.resolve!(
          rules: [%Legion.RateLimiter.Rule{identity: %{"ip" => "203.0.113.42"}}]
        )

      if limiter, do: :ok = limiter.enforce!(agent_id, rules)

  A `nil` limiter means rate limiting is off. An adapter can also be called
  directly with complete rules, skipping `resolve!/1`.

  ## Implementing a rate limiter

  Define a module that implements `enforce!/2` when rate-limit state lives
  outside Postgres or needs application-specific coordination:

      defmodule MyApp.RateLimiter do
        @behaviour Legion.RateLimiter

        @impl Legion.RateLimiter
        def enforce!(agent_id, rules) do
          # Check and record the rate-limit state for every rule, atomically.
          :ok
        end
      end

  An adapter receives all of an agent's rules in one call so it can allow or
  deny the call as a unit. See `Legion.RateLimiter.Rule`,
  `Legion.RateLimiter.Policy`, and `Legion.RateLimiter.Postgres`.
  """
  alias Legion.RateLimiter.Rule
  alias Legion.Store

  @type limit_identity :: %{String.t() => any()}

  @doc """
  Enforces every rule in `rules` for the agent identified by `agent_id`.

  Returns `:ok` when every rule allows the call, and the agent counts towards
  each rule's limits from then on; a denied call counts for nothing. Rules are
  allowed together or denied together, never one by one. How identities match
  and where that state lives is up to the adapter.

  Raises `Legion.RateLimiter.ExceededError` for the first rule, in list order,
  that is exceeded. Legion catches that exception and cancels the turn; any
  other error propagates, so an adapter that cannot reach its backing store
  fails the agent rather than silently allowing the call.
  """
  @callback enforce!(
              agent_id :: Store.agent_id(),
              rules :: [Rule.t()]
            ) ::
              :ok | no_return()

  @off %{limiter: nil, rules: []}

  @doc """
  Resolves the rate limit to enforce.

  `overrides` is an agent's `:rate_limit` option: a keyword list with
  `:limiter` and `:rules`, or `nil` for none. Given `nil`, the calling agent's
  rate limit is returned when called inside an agent, and one resolved from
  the application's `:rate_limit` config otherwise. Given a keyword list, it
  is used as a whole; a missing `:limiter` is taken from the application
  config, and rules without a `:policy` take its `:default_policy`.

  Returns `%{limiter: module | nil, rules: [Legion.RateLimiter.Rule.t()]}`.
  A `nil` limiter or an empty rule list means rate limiting is off; both keys
  are then reset, so the result is always a complete map.

  Raises `ArgumentError` when a keyword list carries keys other than
  `:limiter` and `:rules`, `:rules` is not a list of
  `Legion.RateLimiter.Rule` structs, a rule fails
  `Legion.RateLimiter.Rule.validate!/1`, or two rules give one identity key
  different values. The application config is held to the same keys plus
  `:default_policy`.

  ## Examples

      # config :legion, :rate_limit, limiter: MyApp.RateLimiter, default_policy: policy
      Legion.RateLimiter.resolve!(rules: [%Legion.RateLimiter.Rule{identity: %{"ip" => ip}}])
      #=> %{limiter: MyApp.RateLimiter, rules: [%Legion.RateLimiter.Rule{identity: %{"ip" => ip}, policy: policy}]}

      Legion.RateLimiter.resolve!(nil)
      #=> %{limiter: nil, rules: []}
  """
  def resolve!(nil) do
    Vault.get(:rate_limit) || resolve!(Keyword.take(app_config(), [:limiter, :rules]))
  end

  def resolve!(overrides) when is_list(overrides) do
    overrides = Keyword.validate!(overrides, [:limiter, :rules])
    config = app_config()
    limiter = overrides[:limiter] || config[:limiter]
    rules = overrides |> Keyword.get(:rules, []) |> validate_rules!(config[:default_policy])

    if limiter && rules != [], do: %{limiter: limiter, rules: rules}, else: @off
  end

  defp app_config do
    Keyword.validate!(
      Application.get_env(:legion, :rate_limit, []),
      [:limiter, :rules, :default_policy]
    )
  end

  # The adapter merges an agent's identities into one document, so two rules
  # may share a key only with one value.
  defp validate_rules!(rules, default_policy) when is_list(rules) do
    rules = Enum.map(rules, &fill_policy(&1, default_policy))

    Enum.reduce(rules, %{}, fn rule, seen ->
      Rule.validate!(rule)

      Map.merge(seen, rule.identity, fn key, first, second ->
        first == second ||
          raise ArgumentError,
                "rate-limit rules disagree on #{inspect(key)}: #{inspect(first)} vs #{inspect(second)}"

        first
      end)
    end)

    rules
  end

  defp validate_rules!(other, _default_policy) do
    raise ArgumentError,
          "expected :rules to be a list of #{inspect(Rule)}, got: #{inspect(other)}"
  end

  defp fill_policy(%Rule{policy: nil} = rule, default_policy),
    do: %{rule | policy: default_policy}

  defp fill_policy(rule, _default_policy), do: rule
end
