defmodule Legion.RateLimiter.Postgres do
  @moduledoc """
  A Postgres-backed `Legion.RateLimiter` extending `Legion.Store.Postgres`.

  This adapter depends on an existing `Legion.Store.Postgres` configuration.
  It stores rate-limit metadata and reads agent start times and persisted usage
  from that store's table. Configure the store first, then define a rate
  limiter using the same Ecto repo and table:

      defmodule MyApp.AgentStore do
        use Legion.Store.Postgres, repo: MyApp.Repo
      end

      defmodule MyApp.RateLimiter do
        use Legion.RateLimiter.Postgres, repo: MyApp.Repo
      end

  After the Store migration is in place, add the rate-limiter migration. Roll
  it back before rolling back the Store migration:

      defmodule MyApp.Repo.Migrations.AddLegionRateLimiter do
        use Ecto.Migration

        def up, do: Legion.RateLimiter.Migration.Postgres.up()
        def down, do: Legion.RateLimiter.Migration.Postgres.down()
      end

  Call the generated limiter before admitting work:

      policy = %Legion.RateLimiter.Policy{
        interval_ms: :timer.minutes(1),
        max_agents: 10,
        max_tokens: 100_000
      }

      :ok = MyApp.RateLimiter.enforce!(agent_id, %{provider: "openai"}, policy)

  ## Key matching

  Keys are stored as JSON metadata and matched with Postgres JSON containment.
  A broad key therefore includes metadata with additional fields. For example,
  `%{provider: "openai"}` matches an agent recorded with
  `%{provider: "openai", tenant: "acme"}`. Calling `enforce!/3` again for
  the same agent replaces its stored key while retaining its original start
  time.

  ## Limit evaluation

  The adapter includes the currently admitted agent when it evaluates
  `:max_agents`, so it raises only when that call would make the matching count
  exceed the configured maximum. `:max_tokens` is evaluated from recorded
  `"total_tokens"` usage whose `"at"` timestamp falls inside the policy's
  interval; once that total reaches the configured maximum, later calls raise.

  Token limits require Legion usage tracking, which is enabled by default. If
  your application configures `config :legion, :track_usage, false`, leave
  `:max_tokens` as `nil`; agent limits do not require usage tracking.

  ## Options

    * `:repo` (required) - the Ecto repo used by the configured store.
    * `:table` - the shared Store table name, defaulting to `"legion_agents"`.
      It must also be passed to both Store and rate-limiter migrations.
  """

  alias Legion.RateLimiter.ExceededError

  @doc false
  def enforce!(repo, table, agent_id, key, policy)
      when is_binary(agent_id) and is_map(key) and is_map(policy) do
    meta = stringify_keys(key)

    {:ok, :ok} =
      repo.transaction(fn ->
        upsert_metadata(repo, table, agent_id, meta)

        usage = fetch_usage(repo, table, meta, policy)
        violations = find_violations(usage, policy)

        if violations != [] do
          raise ExceededError,
            agent_id: agent_id,
            key: key,
            policy: policy,
            usage: usage,
            violations: violations
        end

        :ok
      end)

    :ok
  end

  def enforce!(_repo, _table, agent_id, key, policy) do
    raise ArgumentError,
          "invalid rate-limit arguments: " <>
            "#{inspect(agent_id)}, #{inspect(key)}, #{inspect(policy)}"
  end

  defp upsert_metadata(repo, table, agent_id, meta) do
    repo.query!(upsert_metadata_sql(table), [agent_id, meta])
  end

  defp fetch_usage(repo, table, meta, policy) do
    now = DateTime.utc_now()

    %{
      agents: count_agents(repo, table, meta, policy, now),
      tokens: sum_tokens(repo, table, meta, policy, now)
    }
  end

  defp count_agents(_repo, _table, _meta, %{max_agents: nil}, _now), do: nil

  defp count_agents(repo, table, meta, policy, now) do
    cutoff =
      now
      |> DateTime.add(-policy.interval_ms, :millisecond)
      |> DateTime.to_naive()

    scalar!(repo, count_agents_sql(table), [meta, cutoff])
  end

  defp sum_tokens(_repo, _table, _meta, %{max_tokens: nil}, _now), do: nil

  defp sum_tokens(repo, table, meta, policy, now) do
    cutoff = DateTime.to_unix(now, :millisecond) - policy.interval_ms

    scalar!(repo, sum_tokens_sql(table), [meta, cutoff])
  end

  defp scalar!(repo, sql, params) do
    %{rows: [[value]]} = repo.query!(sql, params)
    value
  end

  defp upsert_metadata_sql(table) do
    """
    INSERT INTO #{table} AS agent (
      agent_id,
      limit_meta,
      started_at
    )
    VALUES ($1, $2::jsonb, NOW() AT TIME ZONE 'UTC')
    ON CONFLICT (agent_id) DO UPDATE
    SET
      limit_meta = EXCLUDED.limit_meta,
      started_at = COALESCE(agent.started_at, EXCLUDED.started_at)
    """
  end

  defp count_agents_sql(table) do
    """
    SELECT count(*)::bigint
    FROM #{table}
    WHERE limit_meta @> $1::jsonb
      AND started_at >= $2
    """
  end

  defp sum_tokens_sql(table) do
    """
    SELECT coalesce(sum((entry.value->>'total_tokens')::bigint), 0)::bigint
    FROM #{table} AS agent
    CROSS JOIN unnest(agent.usage) AS entry(value)
    WHERE agent.limit_meta @> $1::jsonb
      AND (entry.value->>'at')::bigint >= $2
    """
  end

  defp find_violations(usage, policy) do
    []
    |> maybe_add_violation(:max_agents, policy.max_agents, usage)
    |> maybe_add_violation(:max_tokens, policy.max_tokens, usage)
  end

  defp maybe_add_violation(violations, _name, nil, _usage), do: violations

  defp maybe_add_violation(violations, :max_agents, limit, usage) do
    if usage.agents > limit, do: violations ++ [:max_agents], else: violations
  end

  defp maybe_add_violation(violations, :max_tokens, limit, usage) do
    if usage.tokens >= limit, do: violations ++ [:max_tokens], else: violations
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "legion_agents")

    quote do
      @behaviour Legion.RateLimiter

      @impl Legion.RateLimiter
      def enforce!(agent_id, key, policy) do
        Legion.RateLimiter.Postgres.enforce!(
          unquote(repo),
          unquote(table),
          agent_id,
          key,
          policy
        )
      end
    end
  end
end
