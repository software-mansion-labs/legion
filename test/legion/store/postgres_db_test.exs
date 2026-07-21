defmodule Legion.Store.PostgresDbTest do
  @moduledoc "Exercises the generated Postgres store against a real database."
  use ExUnit.Case, async: false

  alias Legion.Store.Payload

  defmodule Repo do
    @columns ~w(agent_id agent_module parent_agent_id status started_at conversation_state inserted_at updated_at)a

    def get(_schema, agent_id) do
      case query!("SELECT #{columns_sql()} FROM legion_agents WHERE agent_id = $1", [agent_id]).rows do
        [] -> nil
        [row] -> Map.new(Enum.zip(@columns, row))
      end
    end

    def insert_all(_schema, [attrs], conflict_target: :agent_id, on_conflict: {:replace, columns}) do
      attrs = Map.take(attrs, [:agent_id | columns])
      fields = Map.keys(attrs)
      values = Enum.map(fields, &Map.fetch!(attrs, &1))

      sql = """
      INSERT INTO legion_agents (#{Enum.join(fields, ", ")})
      VALUES (#{placeholders(length(fields))})
      ON CONFLICT (agent_id) DO UPDATE
      SET #{updates_sql(columns)}
      """

      %{num_rows: count} = query!(sql, values)
      {count, nil}
    end

    def query!(sql, params), do: Postgrex.query!(:legion_store_test, sql, params)

    defp columns_sql, do: Enum.join(@columns, ", ")

    defp placeholders(count) do
      1..count
      |> Enum.map_join(", ", &"$#{&1}")
    end

    defp updates_sql(columns) do
      Enum.map_join(columns, ", ", fn column -> "#{column} = EXCLUDED.#{column}" end)
    end
  end

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Store.PostgresDbTest.Repo
  end

  setup do
    Repo.query!("TRUNCATE legion_agents", [])
    :ok
  end

  test "save/1 fully inserts every payload field" do
    payload = %Payload{
      agent_id: "user_42",
      agent_module: Legion.Test.Support.MathAgent,
      parent_agent_id: "parent-1",
      status: :idle,
      started_at: 123,
      conversation_state: %{messages: [%{role: "user", content: "hi"}], bindings: [x: 42]}
    }

    assert :ok = Store.save(payload)
    assert {:ok, ^payload} = Store.get("user_42")
  end

  test "save/1 partially inserts only the supplied payload fields" do
    payload = %Payload{
      agent_id: "state-only",
      conversation_state: %{messages: [%{role: "user", content: "hi"}], bindings: []}
    }

    assert :ok = Store.save(payload)
    assert {:ok, ^payload} = Store.get("state-only")
  end

  test "save/1 partial upsert preserves omitted fields and advances updated_at" do
    initial = %Payload{
      agent_id: "user_42",
      agent_module: Legion.Test.Support.MathAgent,
      parent_agent_id: "parent-1",
      status: :running,
      started_at: 123,
      conversation_state: %{messages: [%{role: "user", content: "hi"}], bindings: [x: 42]}
    }

    assert :ok = Store.save(initial)

    %{rows: [[previous_updated_at]]} =
      Repo.query!("SELECT updated_at FROM legion_agents WHERE agent_id = $1", ["user_42"])

    Process.sleep(1)
    assert :ok = Store.save(%Payload{agent_id: "user_42", status: :idle})

    assert {:ok,
            %Payload{
              agent_module: Legion.Test.Support.MathAgent,
              parent_agent_id: "parent-1",
              status: :idle,
              started_at: 123,
              conversation_state: %{messages: [%{role: "user", content: "hi"}], bindings: [x: 42]}
            }} = Store.get("user_42")

    %{rows: [[updated_at]]} =
      Repo.query!("SELECT updated_at FROM legion_agents WHERE agent_id = $1", ["user_42"])

    assert DateTime.compare(updated_at, previous_updated_at) == :gt
  end

  test "a payload cannot be constructed without agent_id" do
    assert_raise ArgumentError, fn -> struct!(Payload, %{}) end

    %{rows: [[count]]} = Repo.query!("SELECT COUNT(*) FROM legion_agents", [])
    assert count == 0
  end

  test "save/1 rejects unknown payload keys without inserting a row" do
    assert :error = Store.save(%{agent_id: "user_42", unexpected: "value"})

    %{rows: [[count]]} = Repo.query!("SELECT COUNT(*) FROM legion_agents", [])
    assert count == 0
  end
end
