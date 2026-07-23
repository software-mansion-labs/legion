defmodule Legion.Store.PostgresDbTest do
  @moduledoc "Exercises the generated Postgres store against a real database."
  use ExUnit.Case, async: false

  alias Legion.Store.Payload
  alias Legion.Test.Support.PostgresRepo, as: Repo

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Test.Support.PostgresRepo
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
      started_at: ~N[2026-01-01 00:00:00.000000],
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
    assert {:ok, stored} = Store.get("state-only")
    assert stored == %{payload | status: :idle}
  end

  test "save/1 partial upsert preserves omitted fields and advances updated_at" do
    initial = %Payload{
      agent_id: "user_42",
      agent_module: Legion.Test.Support.MathAgent,
      parent_agent_id: "parent-1",
      status: :running,
      started_at: ~N[2026-01-01 00:00:00.000000],
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
              started_at: ~N[2026-01-01 00:00:00.000000],
              conversation_state: %{messages: [%{role: "user", content: "hi"}], bindings: [x: 42]}
            }} = Store.get("user_42")

    %{rows: [[updated_at]]} =
      Repo.query!("SELECT updated_at FROM legion_agents WHERE agent_id = $1", ["user_42"])

    assert NaiveDateTime.compare(updated_at, previous_updated_at) == :gt
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
