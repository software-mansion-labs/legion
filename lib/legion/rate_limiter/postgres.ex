defmodule Legion.RateLimiter.Postgres do
  @moduledoc """
  A Postgres-backed `Legion.RateLimiter` extending `Legion.Store.Postgres`.

  This adapter depends on an existing `Legion.Store.Postgres` configuration.
  It stores rate-limit metadata in that store's table and reads persisted usage from it.
  Configure the store first, then define a rate limiter using the same Ecto repo and table:

      defmodule MyApp.AgentStore do
        use Legion.Store.Postgres, repo: MyApp.Repo
      end

      defmodule MyApp.RateLimiter do
        use Legion.RateLimiter.Postgres, repo: MyApp.Repo
      end

  The Store migration creates the rate-limit metadata column and its GIN index.
  No separate rate-limiter migration is required:

      defmodule MyApp.Repo.Migrations.AddLegionAgents do
        use Ecto.Migration

        def up, do: Legion.Store.Migration.Postgres.up()
        def down, do: Legion.Store.Migration.Postgres.down()
      end

  Call the generated limiter before admitting work:

      policy = %Legion.RateLimiter.Policy{
        interval_ms: :timer.minutes(1),
        max_agents: 10,
        max_tokens: 100_000
      }

      :ok = MyApp.RateLimiter.enforce!(agent_id, %{ip: "203.0.113.42"}, policy)

  For concurrent admission, note that `:max_agents` is not concurrency-safe:
  simultaneous transactions count only rows committed before they started and
  may collectively exceed the configured maximum. Rejected calls are rolled
  back, leaving metadata only for admitted calls.

  ## Key matching

  Keys are stored as JSON metadata and matched with Postgres JSON containment.
  A broad key therefore includes metadata with additional fields. For example,
  `%{ip: "203.0.113.42"}` matches an agent recorded with
  `%{ip: "203.0.113.42", tenant: "acme"}`. Calling `enforce!/3` again for
  the same agent replaces its stored key while retaining its original start
  time.

  ## Limit evaluation

  The adapter includes the currently admitted agent when it evaluates
  `:max_agents`, so it raises only when that call would make the matching count
  exceed the configured maximum. Agents are counted by `started_at`.

  `:max_tokens` is evaluated from recorded `"total_tokens"` usage whose `"at"`
  timestamp falls inside the policy's interval; once that total reaches the
  configured maximum, later calls raise.

  Token limits require Legion usage tracking, which is enabled by default. If
  your application configures `config :legion, :track_usage, false`, leave
  `:max_tokens` as `nil`; agent limits do not require usage tracking.

  ## Options

    * `:repo` (required) - the Ecto repo used by the configured store.
    * `:table` - the shared Store table name, defaulting to `"legion_agents"`.
      It must also be passed to the Store migration.
  """

  alias Legion.RateLimiter.ExceededError
  alias Legion.RateLimiter.Policy

  @doc false
  def enforce!(repo, record, agent_id, rate_limit_key, %Policy{} = policy)
      when is_binary(agent_id) and is_map(rate_limit_key) do
    {:ok, :ok} =
      repo.transaction(fn ->
        upsert_metadata(repo, record, agent_id, rate_limit_key)

        usage = fetch_usage(repo, record, rate_limit_key, policy)

        violations = find_violations(usage, policy)

        if violations != [] do
          raise ExceededError,
            agent_id: agent_id,
            key: rate_limit_key,
            policy: policy,
            usage: usage,
            violations: violations
        end

        :ok
      end)

    :ok
  end

  def enforce!(_repo, _record, agent_id, key, policy) do
    raise ArgumentError,
          "invalid rate-limit arguments: " <>
            "#{inspect(agent_id)}, #{inspect(key)}, #{inspect(policy)}"
  end

  defp upsert_metadata(repo, record, agent_id, meta) do
    {1, _} =
      repo.insert_all(
        record,
        [
          %{
            agent_id: agent_id,
            ratelimit_metadata: meta,
            started_at: NaiveDateTime.utc_now()
          }
        ],
        conflict_target: :agent_id,
        on_conflict: [set: [ratelimit_metadata: meta]]
      )

    :ok
  end

  defp fetch_usage(repo, record, meta, policy) do
    now = DateTime.utc_now()

    %{
      agents: count_agents(repo, record, meta, policy, now),
      tokens: sum_tokens(repo, record, meta, policy, now)
    }
  end

  defp count_agents(_repo, _record, _meta, %{max_agents: nil}, _now), do: nil

  defp count_agents(repo, record, meta, policy, now) do
    import Ecto.Query

    from(agent in record,
      where:
        fragment(
          "? @> ?::jsonb",
          agent.ratelimit_metadata,
          type(^meta, :map)
        ),
      where: agent.started_at >= ^naive_cutoff(now, policy),
      select: count(agent.agent_id)
    )
    |> repo.one()
  end

  defp sum_tokens(_repo, _record, _meta, %{max_tokens: nil}, _now), do: nil

  defp sum_tokens(repo, record, meta, policy, now) do
    import Ecto.Query

    cutoff = DateTime.to_unix(now, :millisecond) - policy.interval_ms

    from(agent in record,
      inner_lateral_join: entry in fragment("SELECT unnest(?) AS value", agent.usage),
      on: true,
      where:
        fragment(
          "? @> ?::jsonb",
          agent.ratelimit_metadata,
          type(^meta, :map)
        ),
      where: fragment("(?->>'at')::bigint >= ?", field(entry, :value), ^cutoff),
      where: agent.updated_at >= ^naive_cutoff(now, policy),
      select:
        fragment(
          "coalesce(sum((?->>'total_tokens')::bigint), 0)::bigint",
          field(entry, :value)
        )
    )
    |> repo.one()
  end

  defp naive_cutoff(now, policy) do
    now
    |> DateTime.add(-policy.interval_ms, :millisecond)
    |> DateTime.to_naive()
  end

  defp find_violations(usage, policy) do
    for {name, true} <- %{
          max_agents: usage.agents != nil and usage.agents > policy.max_agents,
          max_tokens: usage.tokens != nil and usage.tokens >= policy.max_tokens
        },
        do: name
  end

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "legion_agents")

    quote do
      @behaviour Legion.RateLimiter

      alias Legion.RateLimiter

      defmodule Record do
        @moduledoc false

        use Ecto.Schema

        @primary_key {:agent_id, :string, autogenerate: false}

        schema unquote(table) do
          field :started_at, :naive_datetime_usec
          field :usage, {:array, :map}
          field :updated_at, :naive_datetime_usec
          field :ratelimit_metadata, :map
        end
      end

      @impl Legion.RateLimiter
      def enforce!(agent_id, key, policy) do
        RateLimiter.Postgres.enforce!(
          unquote(repo),
          Record,
          agent_id,
          key,
          policy
        )
      end
    end
  end
end
