defmodule Legion.Store.PostgresDbTest do
  @moduledoc """
  Exercises the generated Postgres store against a real database, so the SQL it
  issues - the `ON CONFLICT` upsert in particular - is verified for real rather
  than shape-matched against a fake.
  """
  use ExUnit.Case, async: false

  alias Legion.Store.Conversation
  alias Legion.Store.Conversation.{Metadata, State}

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

  test "save/2 with State round-trips through a real bytea column" do
    state = %State{messages: [%{type: :user, content: "hi"}], bindings: [x: 42]}

    assert :ok = Store.save("user_42", state)
    assert {:ok, %Conversation{agent_id: "user_42", state: ^state}} = Store.get("user_42")
  end

  test "get/1 returns :error when the row is absent" do
    assert :error = Store.get("missing")
  end

  test "save/2 with State upserts on conflict - the latest state wins" do
    assert :ok = Store.save("user_42", %State{messages: [], bindings: [v: 1]})
    assert :ok = Store.save("user_42", %State{messages: [], bindings: [v: 2]})

    assert {:ok, %Conversation{state: %State{bindings: [v: 2]}}} = Store.get("user_42")
  end

  test "save/2 with Metadata records conversation identity and keeps the parent on conflict" do
    metadata = %Metadata{
      agent_module: MyApp.Worker,
      parent_agent_id: "parent-1",
      started_at: 100
    }

    assert :ok = Store.save("child-1", metadata)

    # Resumed from elsewhere: no parent this time, later started_at.
    assert :ok = Store.save("child-1", %{metadata | parent_agent_id: nil, started_at: 200})

    %{rows: [[agent_module, parent_agent_id, started_at]]} =
      Postgrex.query!(
        :legion_store_test,
        "SELECT agent_module, parent_agent_id, started_at FROM legion_agents WHERE agent_id = $1",
        ["child-1"]
      )

    assert agent_module == "MyApp.Worker"
    assert parent_agent_id == "parent-1"
    assert started_at == 200
  end

  test "save/2 with status payload flips the stored status" do
    :ok = Store.save("s1", {:status, :running})
    assert {:ok, %Conversation{status: :running, metadata: nil, state: nil}} = Store.get("s1")

    :ok = Store.save("s1", {:status, :idle})
    assert {:ok, %Conversation{status: :idle}} = Store.get("s1")
  end

  test "save/2 with Metadata does not reset an existing status" do
    metadata = %Metadata{agent_module: A, parent_agent_id: nil, started_at: 2}

    :ok = Store.save("s1", {:status, :running})
    :ok = Store.save("s1", metadata)

    assert {:ok, %Conversation{status: :running, metadata: ^metadata}} = Store.get("s1")
  end

  test "list/1 returns newest conversations including partial rows" do
    state = %State{messages: [], bindings: []}
    metadata = %Metadata{agent_module: A, parent_agent_id: nil, started_at: 1}

    :ok = Store.save("state-only", state)
    :ok = Store.save("metadata-only", metadata)
    :ok = Store.save("status-only", {:status, :idle})

    assert [
             %Conversation{agent_id: "status-only", status: :idle, metadata: nil, state: nil},
             %Conversation{agent_id: "metadata-only", metadata: ^metadata, state: nil},
             %Conversation{agent_id: "state-only", metadata: nil, state: ^state}
           ] = Store.list(10)
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

    :ok = Store.save("notify-1", %Metadata{agent_module: A, parent_agent_id: nil, started_at: 1})
    assert_receive {:notification, _pid, _ref, "legion_agents", "notify-1"}, 1_000

    :ok = Store.save("notify-1", {:status, :running})
    assert_receive {:notification, _pid, _ref, "legion_agents", "notify-1"}, 1_000

    :ok = Store.save("notify-1", %State{messages: [], bindings: []})
    assert_receive {:notification, _pid, _ref, "legion_agents", "notify-1"}, 1_000

    GenServer.stop(notifications)
  end

  test "metadata then state share one row and get/1 sees both" do
    metadata = %Metadata{agent_module: A, parent_agent_id: nil, started_at: 1}

    assert :ok = Store.save("both", metadata)
    assert {:ok, %Conversation{metadata: ^metadata, state: nil}} = Store.get("both")

    state = %State{messages: [%{type: :user, content: "hi"}], bindings: []}
    assert :ok = Store.save("both", state)

    assert {:ok, %Conversation{metadata: ^metadata, state: ^state}} = Store.get("both")

    %{rows: [[count]]} =
      Postgrex.query!(
        :legion_store_test,
        "SELECT COUNT(*) FROM legion_agents WHERE agent_id = $1",
        ["both"]
      )

    assert count == 1
  end
end
