defmodule Legion.Store.PostgresTest do
  use ExUnit.Case, async: true

  defmodule FakeRepo do
    @moduledoc "Emulates repo.query!/2 for the two statements the store issues."

    def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def query!("SELECT snapshot FROM " <> _rest, [agent_id]) do
      case Agent.get(__MODULE__, &Map.fetch(&1, agent_id)) do
        {:ok, snapshot} -> %{rows: [[snapshot]]}
        :error -> %{rows: []}
      end
    end

    def query!("INSERT INTO " <> _rest, [agent_id, snapshot]) do
      Agent.update(__MODULE__, &Map.put(&1, agent_id, snapshot))
      %{num_rows: 1}
    end
  end

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Store.PostgresTest.FakeRepo
  end

  setup do
    start_supervised!(%{id: FakeRepo, start: {FakeRepo, :start_link, []}})
    :ok
  end

  test "save/2 then load/1 round-trips the snapshot through term_to_binary" do
    snapshot = %{messages: [%{role: "user", content: "hi"}], bindings: [x: 42]}

    assert :ok = Store.save("user_42", snapshot)
    assert {:ok, ^snapshot} = Store.load("user_42")
  end

  test "load/1 returns :error when no snapshot exists" do
    assert :error = Store.load("missing")
  end

  test "ids must be strings" do
    assert_raise FunctionClauseError, fn -> Store.load(42) end
    assert_raise FunctionClauseError, fn -> Store.save(42, %{messages: [], bindings: []}) end
  end

  test "a custom table name is interpolated into the statements" do
    defmodule TableCapturingRepo do
      def query!(sql, _params), do: send(self(), {:sql, sql}) && %{rows: []}
    end

    defmodule CustomTableStore do
      use Legion.Store.Postgres,
        repo: Legion.Store.PostgresTest.TableCapturingRepo,
        table: "my_agents"
    end

    CustomTableStore.load("user_42")

    assert_received {:sql, "SELECT snapshot FROM my_agents WHERE agent_id = $1"}
  end
end
