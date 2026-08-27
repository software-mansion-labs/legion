defmodule Legion.RateLimiter do
  @moduledoc """
  Behaviour for enforcing rate limits across Legion agents.

  A rate limiter decides whether an agent may proceed under a list of
  `Legion.RateLimiter.Rule`s. Each rule pairs an identity - the cohort of
  agents sharing a limit - with a `Legion.RateLimiter.Policy`. Legion calls
  `enforce!/2` for you: configure a limiter and rules, and every turn is
  admitted through them.

      Legion.start_link(ChatAgent,
        rate_limit: [
          limiter: MyApp.RateLimiter,
          rules: [
            %Legion.RateLimiter.Rule{
              identity: %{"ip" => "203.0.113.42", "tenant" => "acme"},
              policy: %Legion.RateLimiter.Policy{
                interval_ms: :timer.minutes(30),
                max_agents: 40,
                max_tokens: 200_000
              }
            },
            %Legion.RateLimiter.Rule{
              identity: %{"email" => "someone@example.com"},
              policy: %Legion.RateLimiter.Policy{interval_ms: :timer.hours(24), max_agents: 5}
            }
          ]
        ]
      )

  Every rule must admit the agent; the first rule that refuses cancels the
  turn. Rules are evaluated in the order given, so put the rule whose refusal
  you want reported first.

  ## Configuration

  The limiter and a default policy can be set globally, leaving only the
  identities to the call site:

      config :legion, :rate_limit,
        limiter: MyApp.RateLimiter,
        default_policy: %Legion.RateLimiter.Policy{interval_ms: :timer.minutes(1), max_agents: 10}

      Legion.start_link(ChatAgent,
        rate_limit: [rules: [%Legion.RateLimiter.Rule{identity: %{"ip" => "203.0.113.42"}}]]
      )

  A rule given without a `:policy` takes the default one. Rate limiting applies
  only when a limiter and at least one rule resolve; a limiter without rules,
  or rules without a limiter, disables it. Sub-agents inherit whatever their
  parent resolved and cannot override it; each sub-agent is a separate agent ID
  in every cohort, so it counts towards `:max_agents` and its usage towards
  `:max_tokens`.

  Rules must agree on their identities: two rules may share a field only with
  the same value, since the adapter records one cohort membership per agent.
  Two rules with the same identity and different policies are fine - for
  example a per-minute and a per-day window on one IP. Identity keys must be
  strings; an empty identity `%{}` matches every agent and acts as a global cap.

  ## When Legion enforces

  Enforcement happens once per turn, before the incoming message is appended
  and before any LLM request. A refusal therefore leaves the conversation
  untouched and costs nothing.

  Refused turns return `{:cancel, {:rate_limited, violations}}` - the same
  shape as `{:cancel, :reached_max_iterations}` - so a refused sub-agent
  reports back to its caller as a value rather than a crash. Legion also emits
  `[:legion, :rate_limit, :exceeded]` with the identity and policy of the rule
  that refused; see `Legion.Telemetry`.

  Resumed and recovered runs are *not* re-admitted. They are finishing work
  that was already admitted, so re-checking them would discard accepted work
  instead of shedding new load.

  ## Calling it yourself

  `enforce!/2` is public, so an application can also admit its own work under
  the same rules - a webhook, a queue worker - by passing a stable id and a
  list of complete rules:

      :ok =
        MyApp.RateLimiter.enforce!(agent_id, [
          %Legion.RateLimiter.Rule{identity: %{"ip" => "203.0.113.42"}, policy: policy}
        ])

  The behaviour is the seam for custom rate-limiter adapters. The bundled
  `Legion.RateLimiter.Postgres` adapter records cohort metadata and evaluates
  policies from the same Postgres table used by `Legion.Store.Postgres`.

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

  An adapter receives all of an agent's rules in one call so it can admit or
  refuse them as a unit. See `Legion.RateLimiter.Rule`,
  `Legion.RateLimiter.Policy`, and `Legion.RateLimiter.Postgres`.
  """
  alias Legion.RateLimiter.Rule
  alias Legion.Store

  @type limit_identity :: %{String.t() => any()}

  @doc """
  Enforces every rule in `rules` for the agent identified by `agent_id`.

  Returns `:ok` when the adapter admits the agent under all rules. The adapter
  defines how identities match and how it stores rate-limit state; it must
  treat the list as one admission, leaving no state behind when any rule
  refuses.

  Raises `Legion.RateLimiter.ExceededError` for the first rule, in list order,
  whose limits have been reached. Legion catches that exception and cancels
  the turn; any other error propagates, so an adapter that cannot reach its
  backing store fails the agent rather than silently admitting it.
  """
  @callback enforce!(
              agent_id :: Store.agent_id(),
              rules :: [Rule.t()]
            ) ::
              :ok | no_return()

  @doc false
  def resolve!(nil), do: resolve!([])

  def resolve!(overrides) when is_list(overrides) do
    app_config = Application.get_env(:legion, :rate_limit, [])
    overrides = fill_policies(overrides, Keyword.get(app_config, :default_policy))

    %{limiter: nil, rules: []}
    |> Map.merge(layer(app_config))
    |> Map.merge(layer(Vault.get(:rate_limit) || %{}))
    |> Map.merge(layer(overrides))
    |> finish!()
  end

  defp fill_policies(overrides, default_policy) do
    case Keyword.fetch(overrides, :rules) do
      {:ok, rules} when is_list(rules) ->
        Keyword.put(overrides, :rules, Enum.map(rules, &fill(&1, default_policy)))

      {:ok, other} ->
        raise ArgumentError, "expected :rules to be a list, got: #{inspect(other)}"

      :error ->
        overrides
    end
  end

  defp fill(%Rule{policy: nil} = rule, default_policy), do: %{rule | policy: default_policy}
  defp fill(%Rule{} = rule, _default_policy), do: rule

  defp fill(other, _default_policy),
    do: raise(ArgumentError, "expected a #{inspect(Rule)} in :rules, got: #{inspect(other)}")

  defp layer(config), do: config |> Map.new() |> Map.take([:limiter, :rules])

  defp finish!(%{limiter: limiter, rules: rules}) do
    Enum.each(rules, &Rule.validate!/1)
    validate_identities!(rules)

    if is_nil(limiter) or rules == [], do: nil, else: %{limiter: limiter, rules: rules}
  end

  defp validate_identities!(rules) do
    Enum.reduce(rules, %{}, fn rule, seen ->
      Map.merge(seen, rule.identity, fn key, a, b ->
        a == b ||
          raise ArgumentError,
                "rate-limit rules disagree on #{inspect(key)}: #{inspect(a)} vs #{inspect(b)}"

        a
      end)
    end)
  end
end
