defmodule Legion.RateLimiter.PostgresDbTest do
  use ExUnit.Case, async: false

  alias Legion.RateLimiter.ExceededError
  alias Legion.RateLimiter.Policy
  alias Legion.Test.Support.LegionAgentsMigration
  alias Legion.Test.Support.PostgresRepo, as: Repo

  @ip_key %{ip: "203.0.113.42"}
  @other_ip_key %{ip: "198.51.100.7"}
  @tenant_ip_key %{ip: "203.0.113.42", tenant: "acme"}

  defmodule RateLimiter do
    use Legion.RateLimiter.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  setup do
    Repo.query!("TRUNCATE legion_agents", [])
    :ok
  end

  test "allows exactly max_agents newly started matching agents" do
    policy = policy(max_agents: 2)

    assert :ok = RateLimiter.enforce!("first", @ip_key, policy)
    assert :ok = RateLimiter.enforce!("second", @ip_key, policy)
  end

  test "rejects the agent that would exceed max_agents" do
    policy = policy(max_agents: 1)

    assert :ok = RateLimiter.enforce!("first", @ip_key, policy)

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("second", @ip_key, policy)
    end
  end

  test "counts a broader key's agents with more specific metadata" do
    policy = policy(max_agents: 1)

    assert :ok = RateLimiter.enforce!("acme", @tenant_ip_key, policy)

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("ip-wide", @ip_key, policy)
    end
  end

  test "does not count agents whose starts predate the agent window" do
    insert_agent("old", @ip_key, started_at: milliseconds_ago(2_000))

    assert :ok =
             RateLimiter.enforce!(
               "new",
               @ip_key,
               policy(interval_ms: 1_000, max_agents: 1)
             )
  end

  test "counts timestamped token usage from agents started before the window" do
    insert_agent("long-running", @ip_key,
      started_at: milliseconds_ago(2_000),
      usage: [usage(total_tokens: 10, at: timestamp_milliseconds_ago(100))]
    )

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(
        "new",
        @ip_key,
        policy(interval_ms: 1_000, max_tokens: 10)
      )
    end
  end

  test "does not count token usage outside the token window" do
    insert_agent("long-running", @ip_key,
      usage: [usage(total_tokens: 10, at: timestamp_milliseconds_ago(2_000))]
    )

    assert :ok =
             RateLimiter.enforce!(
               "new",
               @ip_key,
               policy(interval_ms: 1_000, max_tokens: 10)
             )
  end

  # Usage is only ever appended by a store save, and every save bumps
  # updated_at, so a row untouched since before the window cannot hold usage
  # inside it. Skipping those rows keeps the token sum proportional to the
  # window rather than to the whole history of the cohort.
  test "ignores rows untouched since before the token window" do
    insert_agent("stale", @ip_key,
      usage: [usage(total_tokens: 10, at: timestamp_milliseconds_ago(100))],
      updated_at: milliseconds_ago(2_000)
    )

    assert :ok =
             RateLimiter.enforce!(
               "new",
               @ip_key,
               policy(interval_ms: 1_000, max_tokens: 10)
             )
  end

  test "rejects when recorded tokens reach max_tokens" do
    insert_agent("first", @ip_key, usage: [usage(total_tokens: 10)])

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("next", @ip_key, policy(max_tokens: 10))
    end
  end

  test "reports every active violation without requiring an order" do
    insert_agent("first", @ip_key, usage: [usage(total_tokens: 10)])

    error =
      assert_raise ExceededError, fn ->
        RateLimiter.enforce!("next", @ip_key, policy(max_agents: 1, max_tokens: 10))
      end

    assert MapSet.new(error.violations) == MapSet.new([:max_agents, :max_tokens])
  end

  test "zero limits allow none" do
    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("agent-limit", @ip_key, policy(max_agents: 0))
    end

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("token-limit", @other_ip_key, policy(max_tokens: 0))
    end
  end

  test "allows an unrestricted policy" do
    assert :ok = RateLimiter.enforce!("unrestricted", @ip_key, policy())
  end

  test "moves an agent to its new key without resetting its start time" do
    assert :ok = RateLimiter.enforce!("agent", @ip_key, policy())

    assert :ok = RateLimiter.enforce!("agent", @other_ip_key, policy())

    assert :ok =
             RateLimiter.enforce!("ip-agent", @ip_key, policy(max_agents: 1))

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("other-ip-agent", @other_ip_key, policy(max_agents: 1))
    end
  end

  test "rolls back a rejected new agent's metadata" do
    assert :ok = RateLimiter.enforce!("first", @ip_key, policy(max_agents: 1))

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("rejected", @ip_key, policy(max_agents: 1))
    end

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM legion_agents WHERE agent_id = $1", ["rejected"])
  end

  # `max_agents` is not concurrency-safe: each transaction counts only rows
  # committed before it started, so simultaneous starts can overshoot the
  # limit. What must hold is that every caller gets a verdict and that only
  # admitted agents leave a row behind.
  test "gives every concurrent caller a verdict and records only the admitted ones" do
    policy = policy(max_agents: 1)
    test_pid = self()

    tasks =
      for index <- 1..20 do
        Task.async(fn ->
          send(test_pid, {:ready, self()})

          receive do
            :enforce ->
              try do
                RateLimiter.enforce!("concurrent-#{index}", @ip_key, policy)
              rescue
                ExceededError -> :exceeded
              end
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    Enum.each(tasks, &send(&1.pid, :enforce))

    outcomes = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.all?(outcomes, &(&1 in [:ok, :exceeded]))
    assert Enum.any?(outcomes, &(&1 == :ok))

    %{rows: [[recorded]]} =
      Repo.query!("SELECT count(*) FROM legion_agents WHERE ratelimit_metadata IS NOT NULL", [])

    assert recorded == Enum.count(outcomes, &(&1 == :ok))
  end

  test "migration can be rolled back, reapplied, and rerun safely" do
    version = LegionAgentsMigration.version()

    assert :ok = Ecto.Migrator.down(Repo, version, LegionAgentsMigration, log: false)
    refute column_exists?("ratelimit_metadata")
    refute index_exists?("legion_agents_ratelimit_metadata_gin_idx")

    assert :already_down =
             Ecto.Migrator.down(Repo, version, LegionAgentsMigration, log: false)

    assert :ok = Ecto.Migrator.up(Repo, version, LegionAgentsMigration, log: false)
    assert column_exists?("ratelimit_metadata")
    assert index_exists?("legion_agents_ratelimit_metadata_gin_idx")
    assert :already_up = Ecto.Migrator.up(Repo, version, LegionAgentsMigration, log: false)
  end

  defp policy(opts \\ []) do
    struct!(Policy, Keyword.merge([interval_ms: 60_000, max_agents: nil, max_tokens: nil], opts))
  end

  defp usage(opts) do
    total_tokens = Keyword.fetch!(opts, :total_tokens)
    at = Keyword.get(opts, :at, System.system_time(:millisecond))

    %{"total_tokens" => total_tokens, "at" => at}
  end

  defp insert_agent(agent_id, key, opts) do
    started_at = Keyword.get(opts, :started_at, NaiveDateTime.utc_now())
    usage = Keyword.get(opts, :usage, [])
    updated_at = Keyword.get(opts, :updated_at, NaiveDateTime.utc_now())

    Repo.query!(
      """
      INSERT INTO legion_agents (
        agent_id, ratelimit_metadata, started_at, usage, updated_at
      )
      VALUES ($1, $2::jsonb, $3, $4::jsonb[], $5)
      """,
      [agent_id, key, started_at, usage, updated_at]
    )
  end

  defp milliseconds_ago(milliseconds) do
    DateTime.utc_now()
    |> DateTime.add(-milliseconds, :millisecond)
    |> DateTime.to_naive()
  end

  defp timestamp_milliseconds_ago(milliseconds),
    do: System.system_time(:millisecond) - milliseconds

  defp column_exists?(column) do
    %{rows: [[exists?]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_name = 'legion_agents' AND column_name = $1
        )
        """,
        [column]
      )

    exists?
  end

  defp index_exists?(index) do
    %{rows: [[exists?]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [index])
    exists?
  end
end
