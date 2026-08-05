defmodule Legion.Store.PostgresTest do
  use ExUnit.Case, async: true

  alias Legion.Store.Payload

  defmodule FakeRepo do
    @moduledoc "Emulates the Ecto repository calls made by the generated store."

    def start_link, do: Agent.start_link(fn -> %{rows: %{}} end, name: __MODULE__)

    def get(_schema, agent_id) do
      Agent.get(__MODULE__, &Map.get(&1.rows, agent_id))
    end

    def all(_query), do: Agent.get(__MODULE__, &Map.values(&1.rows))

    def insert_all(_schema, [attrs], conflict_target: :agent_id, on_conflict: {:replace, columns}) do
      Agent.update(__MODULE__, fn state ->
        row =
          state.rows
          |> Map.get(attrs.agent_id, empty_row(attrs.agent_id))
          |> Map.merge(Map.take(attrs, [:agent_id | columns]))

        put_in(state.rows[attrs.agent_id], row)
      end)

      {1, nil}
    end

    def run(agent_id), do: Agent.get(__MODULE__, &Map.get(&1.rows, agent_id))

    defp empty_row(agent_id) do
      %{
        agent_id: agent_id,
        agent_module: nil,
        parent_agent_id: nil,
        status: "idle",
        started_at: nil,
        conversation_state: nil,
        inserted_at: nil,
        updated_at: nil
      }
    end
  end

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Store.PostgresTest.FakeRepo
  end

  defmodule StepStore do
    use Legion.Store.Postgres,
      repo: Legion.Store.PostgresTest.FakeRepo,
      persistence_frequency: :step
  end

  setup do
    start_supervised!(%{id: FakeRepo, start: {FakeRepo, :start_link, []}})
    :ok
  end

  test "generated stores expose their configured persistence frequency" do
    assert Legion.Store.persistence_frequency(Store) == :turn
    assert Legion.Store.persistence_frequency(StepStore) == :step
  end

  test "save/1 fully inserts every payload field" do
    payload = %Payload{
      agent_id: "user_42",
      agent_module: Legion.Test.Support.MathAgent,
      parent_agent_id: "parent-1",
      status: :idle,
      started_at: 123,
      conversation_state: %{
        messages: [%{role: "user", content: "hi"}],
        bindings: [x: 42],
        executor_state: nil
      }
    }

    assert :ok = Store.save(payload)
    assert {:ok, ^payload} = Store.get("user_42")
  end

  test "save/1 partially inserts only the supplied payload fields" do
    payload = %Payload{
      agent_id: "state-only",
      conversation_state: %{
        messages: [%{role: "user", content: "hi"}],
        bindings: [],
        executor_state: nil
      }
    }

    expected_payload = %{payload | status: :idle}
    assert :ok = Store.save(payload)
    assert {:ok, ^expected_payload} = Store.get("state-only")
  end

  test "save/1 round trips executor_state for a step checkpoint" do
    executor_state = %{phase: :awaiting_llm, iteration: 2, retries: 1}

    payload = %Payload{
      agent_id: "step-state",
      status: :running,
      conversation_state: %{
        messages: [%{role: "user", content: "result"}],
        bindings: [x: 42],
        executor_state: executor_state
      }
    }

    assert :ok = Store.save(payload)
    assert {:ok, ^payload} = Store.get("step-state")
  end

  test "save/1 partial upsert preserves omitted fields and advances updated_at" do
    initial = %Payload{
      agent_id: "user_42",
      agent_module: Legion.Test.Support.MathAgent,
      parent_agent_id: "parent-1",
      status: :running,
      started_at: 123,
      conversation_state: %{
        messages: [%{role: "user", content: "hi"}],
        bindings: [x: 42],
        executor_state: nil
      }
    }

    assert :ok = Store.save(initial)
    previous_updated_at = FakeRepo.run("user_42").updated_at

    assert :ok = Store.save(%Payload{agent_id: "user_42", status: :idle})

    assert {:ok,
            %Payload{
              agent_module: Legion.Test.Support.MathAgent,
              parent_agent_id: "parent-1",
              status: :idle,
              started_at: 123,
              conversation_state: %{
                messages: [%{role: "user", content: "hi"}],
                bindings: [x: 42],
                executor_state: nil
              }
            }} = Store.get("user_42")

    assert NaiveDateTime.compare(FakeRepo.run("user_42").updated_at, previous_updated_at) == :gt
  end

  test "a payload cannot be constructed without agent_id" do
    assert_raise ArgumentError, fn -> struct!(Payload, %{}) end
    assert FakeRepo.run("missing") == nil
  end

  test "save/1 rejects unknown payload keys without inserting a row" do
    assert :error = Store.save(%{agent_id: "user_42", unexpected: "value"})
    assert FakeRepo.run("user_42") == nil
  end
end
