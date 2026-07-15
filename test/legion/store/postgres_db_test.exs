defmodule Legion.Store.PostgresDbTest do
  @moduledoc """
  Exercises the generated Postgres store against a real database, so the SQL it
  issues - the `ON CONFLICT` upsert in particular - is verified for real rather
  than shape-matched against a fake.
  """
  use ExUnit.Case, async: false

  defmodule Repo do
    def query!(sql, params), do: Postgrex.query!(:legion_store_test, sql, params)
  end

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Store.PostgresDbTest.Repo
  end

  setup do
    Postgrex.query!(:legion_store_test, "TRUNCATE legion_agents", [])
    :ok
  end

  test "round-trips a snapshot through a real bytea column" do
    snapshot = %{messages: [%{role: "user", content: "hi"}], bindings: [x: 42]}

    assert :ok = Store.save("user_42", snapshot)
    assert {:ok, ^snapshot} = Store.load("user_42")
  end

  test "load/1 returns :error when the row is absent" do
    assert :error = Store.load("missing")
  end

  test "save/2 upserts on conflict - the latest snapshot wins" do
    assert :ok = Store.save("user_42", %{messages: [], bindings: [v: 1]})
    assert :ok = Store.save("user_42", %{messages: [], bindings: [v: 2]})

    assert {:ok, %{bindings: [v: 2]}} = Store.load("user_42")
  end

  test "save_run/2 records conversation identity and keeps the parent on conflict" do
    metadata = %{
      agent_module: MyApp.Worker,
      parent_agent_id: "parent-1",
      pid: self(),
      started_at: 100
    }

    assert :ok = Store.save_run("child-1", metadata)

    # Resumed from elsewhere: no parent this time, later started_at.
    assert :ok = Store.save_run("child-1", %{metadata | parent_agent_id: nil, started_at: 200})

    %{rows: [[agent_module, parent_agent_id, started_at]]} =
      Postgrex.query!(
        :legion_store_test,
        "SELECT agent_module, parent_agent_id, started_at FROM legion_agents WHERE agent_id = $1",
        ["child-1"]
      )

    assert agent_module == "MyApp.Worker"
    assert parent_agent_id == "parent-1"
    assert started_at == 200
    assert %{pid: pid} = Store.get_run("child-1")
    assert pid == self()
  end

  test "save_status/2 flips the stored status and save_run/2 resets it to idle" do
    :ok = Store.save_run("s1", %{agent_module: A, parent_agent_id: nil, started_at: 1})
    assert %{status: :idle} = Store.get_run("s1")

    :ok = Store.save_status("s1", :running)
    assert %{status: :running} = Store.get_run("s1")

    :ok = Store.save_run("s1", %{agent_module: A, parent_agent_id: nil, started_at: 2})
    assert %{status: :idle} = Store.get_run("s1")
  end

  test "the trigger notifies the table's channel with the agent_id on every write" do
    {:ok, notifications} =
      Postgrex.Notifications.start_link(
        hostname: System.get_env("POSTGRES_HOST", "localhost"),
        port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
        username: System.get_env("POSTGRES_USER", "postgres"),
        password: System.get_env("POSTGRES_PASSWORD", "postgres"),
        database: System.get_env("POSTGRES_DB", "postgres")
      )

    {:ok, _ref} = Postgrex.Notifications.listen(notifications, "legion_agents")

    :ok = Store.save_run("notify-1", %{agent_module: A, parent_agent_id: nil, started_at: 1})
    assert_receive {:notification, _pid, _ref, "legion_agents", "notify-1"}, 1_000

    :ok = Store.save_status("notify-1", :running)
    assert_receive {:notification, _pid, _ref, "legion_agents", "notify-1"}, 1_000

    :ok = Store.save("notify-1", %{messages: [], bindings: []})
    assert_receive {:notification, _pid, _ref, "legion_agents", "notify-1"}, 1_000

    GenServer.stop(notifications)
  end

  test "save_run/2 then save/2 share one row and load/1 sees the snapshot" do
    assert :ok = Store.save_run("both", %{agent_module: A, parent_agent_id: nil, started_at: 1})
    assert :error = Store.load("both")

    snapshot = %{messages: [%{role: "user", content: "hi"}], bindings: []}
    assert :ok = Store.save("both", snapshot)

    assert {:ok, ^snapshot} = Store.load("both")

    %{rows: [[count]]} =
      Postgrex.query!(
        :legion_store_test,
        "SELECT COUNT(*) FROM legion_agents WHERE agent_id = $1",
        ["both"]
      )

    assert count == 1
  end
end
