defmodule Legion.RateLimiter.PostgresDbTest do
  use ExUnit.Case, async: false

  alias Legion.RateLimiter.ExceededError
  alias Legion.RateLimiter.Policy
  alias Legion.Test.Support.LegionRateLimiterMigration
  alias Legion.Test.Support.PostgresRepo, as: Repo

  defmodule RateLimiter do
    use Legion.RateLimiter.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  setup do
    Repo.query!("TRUNCATE legion_agents", [])
    :ok
  end

  test "allows exactly max_agents newly started matching agents" do
    policy = policy(max_agents: 2)

    assert :ok = RateLimiter.enforce!("first", %{provider: "openai"}, policy)
    assert :ok = RateLimiter.enforce!("second", %{provider: "openai"}, policy)
  end

  test "rejects the agent that would exceed max_agents" do
    policy = policy(max_agents: 1)

    assert :ok = RateLimiter.enforce!("first", %{provider: "openai"}, policy)

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("second", %{provider: "openai"}, policy)
    end
  end

  test "counts a broader key's agents with more specific metadata" do
    policy = policy(max_agents: 1)

    assert :ok = RateLimiter.enforce!("acme", %{provider: "openai", tenant: "acme"}, policy)

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("provider-wide", %{provider: "openai"}, policy)
    end
  end

  test "does not count agents whose starts predate the agent window" do
    insert_agent("old", %{provider: "openai"}, started_at: milliseconds_ago(2_000))

    assert :ok =
             RateLimiter.enforce!(
               "new",
               %{provider: "openai"},
               policy(interval_ms: 1_000, max_agents: 1)
             )
  end

  test "counts timestamped token usage from agents that started before the window" do
    insert_agent("long-running", %{provider: "openai"},
      started_at: milliseconds_ago(2_000),
      usage: [usage(total_tokens: 10, at: timestamp_milliseconds_ago(100))]
    )

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(
        "new",
        %{provider: "openai"},
        policy(interval_ms: 1_000, max_tokens: 10)
      )
    end
  end

  test "does not count token usage outside the token window" do
    insert_agent("long-running", %{provider: "openai"},
      usage: [usage(total_tokens: 10, at: timestamp_milliseconds_ago(2_000))]
    )

    assert :ok =
             RateLimiter.enforce!(
               "new",
               %{provider: "openai"},
               policy(interval_ms: 1_000, max_tokens: 10)
             )
  end

  test "rejects when recorded tokens reach max_tokens" do
    insert_agent("first", %{provider: "openai"}, usage: [usage(total_tokens: 10)])

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("next", %{provider: "openai"}, policy(max_tokens: 10))
    end
  end

  test "reports every active violation without requiring an order" do
    insert_agent("first", %{provider: "openai"}, usage: [usage(total_tokens: 10)])

    error =
      assert_raise ExceededError, fn ->
        RateLimiter.enforce!("next", %{provider: "openai"}, policy(max_agents: 1, max_tokens: 10))
      end

    assert MapSet.new(error.violations) == MapSet.new([:max_agents, :max_tokens])
  end

  test "zero limits allow none" do
    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("agent-limit", %{provider: "openai"}, policy(max_agents: 0))
    end

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("token-limit", %{provider: "anthropic"}, policy(max_tokens: 0))
    end
  end

  test "allows an unrestricted policy" do
    assert :ok = RateLimiter.enforce!("unrestricted", %{provider: "openai"}, policy())
  end

  test "moves an agent to its new key without resetting its start time" do
    assert :ok = RateLimiter.enforce!("agent", %{provider: "openai"}, policy())

    started_at = agent_started_at("agent")

    assert :ok = RateLimiter.enforce!("agent", %{provider: "anthropic"}, policy())

    assert agent_started_at("agent") == started_at

    assert :ok =
             RateLimiter.enforce!("openai-agent", %{provider: "openai"}, policy(max_agents: 1))

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("anthropic-agent", %{provider: "anthropic"}, policy(max_agents: 1))
    end
  end

  test "rolls back a rejected new agent's metadata" do
    assert :ok = RateLimiter.enforce!("first", %{provider: "openai"}, policy(max_agents: 1))

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("rejected", %{provider: "openai"}, policy(max_agents: 1))
    end

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM legion_agents WHERE agent_id = $1", ["rejected"])
  end

  test "admits no more than max_agents concurrent agents" do
    policy = policy(max_agents: 1)
    test_pid = self()

    tasks =
      for index <- 1..20 do
        Task.async(fn ->
          send(test_pid, {:ready, self()})

          receive do
            :enforce ->
              try do
                RateLimiter.enforce!("concurrent-#{index}", %{provider: "openai"}, policy)
              rescue
                ExceededError -> :exceeded
              end
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    Enum.each(tasks, &send(&1.pid, :enforce))

    outcomes = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(outcomes, &(&1 == :ok)) == 1
    assert Enum.count(outcomes, &(&1 == :exceeded)) == 19
  end

  test "migration can be rolled back, reapplied, and rerun safely" do
    version = LegionRateLimiterMigration.version()

    assert :ok = Ecto.Migrator.down(Repo, version, LegionRateLimiterMigration, log: false)
    refute column_exists?("limit_meta")
    refute index_exists?("legion_agents_limit_meta_gin_idx")
    refute index_exists?("legion_agents_started_at_index")

    assert :already_down =
             Ecto.Migrator.down(Repo, version, LegionRateLimiterMigration, log: false)

    assert :ok = Ecto.Migrator.up(Repo, version, LegionRateLimiterMigration, log: false)
    assert column_exists?("limit_meta")
    assert index_exists?("legion_agents_limit_meta_gin_idx")
    assert index_exists?("legion_agents_started_at_index")
    assert :already_up = Ecto.Migrator.up(Repo, version, LegionRateLimiterMigration, log: false)
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

    Repo.query!(
      """
      INSERT INTO legion_agents (agent_id, limit_meta, started_at, usage, updated_at)
      VALUES ($1, $2::jsonb, $3, $4::jsonb[], NOW() AT TIME ZONE 'UTC')
      """,
      [agent_id, key, started_at, usage]
    )
  end

  defp agent_started_at(agent_id) do
    %{rows: [[started_at]]} =
      Repo.query!("SELECT started_at FROM legion_agents WHERE agent_id = $1", [agent_id])

    started_at
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
