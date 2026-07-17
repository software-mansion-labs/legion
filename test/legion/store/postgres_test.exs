defmodule Legion.Store.PostgresTest do
  use ExUnit.Case, async: true

  alias Legion.Store.Conversation
  alias Legion.Store.Conversation.{Metadata, State}

  defmodule FakeRepo do
    @moduledoc "Emulates repo.query!/2 for the statements the store issues."

    def start_link, do: Agent.start_link(fn -> %{rows: %{}, clock: 0} end, name: __MODULE__)

    def query!("SELECT agent_id" <> _rest = sql, [param]) do
      rows =
        Agent.get(__MODULE__, fn state ->
          state.rows
          |> select_rows(sql, param)
          |> Enum.map(&row/1)
        end)

      %{rows: rows}
    end

    def query!("INSERT INTO " <> _rest = sql, [agent_id, value]) do
      cond do
        String.contains?(sql, "(agent_id, conversation_state") ->
          update_row(agent_id, %{conversation_state: value})
          %{num_rows: 1}

        String.contains?(sql, "(agent_id, status") ->
          update_row(agent_id, %{status: value})
          %{num_rows: 1}

        true ->
          raise ArgumentError, "unexpected two-argument insert: #{sql}"
      end
    end

    def query!("INSERT INTO " <> _rest = sql, [
          agent_id,
          agent_module,
          parent_agent_id,
          started_at
        ]) do
      if String.contains?(sql, "(agent_id, agent_module, parent_agent_id, started_at") do
        Agent.update(__MODULE__, fn state ->
          row = Map.get(state.rows, agent_id, empty_row(agent_id))

          put_in(state.rows[agent_id], %{
            row
            | agent_module: agent_module,
              parent_agent_id: row.parent_agent_id || parent_agent_id,
              started_at: started_at,
              updated_at: state.clock + 1
          })
          |> Map.update!(:clock, &(&1 + 1))
        end)

        %{num_rows: 1}
      else
        raise ArgumentError, "unexpected metadata insert: #{sql}"
      end
    end

    def run(agent_id), do: Agent.get(__MODULE__, & &1.rows[agent_id])

    defp select_rows(rows, sql, param) do
      if String.contains?(sql, "WHERE agent_id") do
        select_row(rows, param)
      else
        select_recent_rows(rows, param)
      end
    end

    defp select_row(rows, agent_id) do
      rows
      |> Map.values()
      |> Enum.filter(&(&1.agent_id == agent_id))
    end

    defp select_recent_rows(rows, limit) do
      rows
      |> Map.values()
      |> Enum.sort_by(& &1.updated_at, :desc)
      |> Enum.take(limit)
    end

    defp update_row(agent_id, attrs) do
      Agent.update(__MODULE__, fn state ->
        row =
          state.rows
          |> Map.get(agent_id, empty_row(agent_id))
          |> Map.merge(attrs)
          |> Map.put(:updated_at, state.clock + 1)

        state
        |> put_in([:rows, agent_id], row)
        |> Map.update!(:clock, &(&1 + 1))
      end)
    end

    defp empty_row(agent_id) do
      %{
        agent_id: agent_id,
        agent_module: nil,
        parent_agent_id: nil,
        status: nil,
        started_at: nil,
        conversation_state: nil,
        updated_at: 0
      }
    end

    defp row(row) do
      [
        row.agent_id,
        row.agent_module,
        row.parent_agent_id,
        row.status,
        row.started_at,
        row.conversation_state
      ]
    end
  end

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Store.PostgresTest.FakeRepo
  end

  setup do
    start_supervised!(%{id: FakeRepo, start: {FakeRepo, :start_link, []}})
    :ok
  end

  test "save/2 with State then get/1 returns a conversation with decoded state" do
    state = %State{messages: [%{type: :user, content: "hi"}], bindings: [x: 42]}

    assert :ok = Store.save("user_42", state)

    assert {:ok,
            %Conversation{
              agent_id: "user_42",
              metadata: nil,
              status: nil,
              state: ^state
            }} = Store.get("user_42")
  end

  test "get/1 returns :error when the row is absent" do
    assert :error = Store.get("missing")
  end

  test "ids must be strings" do
    assert_raise FunctionClauseError, fn -> Store.get(42) end
    assert :error = Store.save(42, %State{messages: [], bindings: []})
  end

  test "save/2 with Metadata stores the module in inspect form with parent and start time" do
    metadata = %Metadata{
      agent_module: Legion.Test.Support.MathAgent,
      parent_agent_id: "p1",
      started_at: 123
    }

    assert :ok = Store.save("user_42", metadata)

    assert %{
             agent_module: "Legion.Test.Support.MathAgent",
             parent_agent_id: "p1",
             status: nil,
             started_at: 123,
             conversation_state: nil
           } = FakeRepo.run("user_42")
  end

  test "save/2 with status payload flips the stored status and get/1 decodes it" do
    :ok = Store.save("s1", {:status, :running})
    assert {:ok, %Conversation{status: :running, metadata: nil, state: nil}} = Store.get("s1")

    :ok = Store.save("s1", {:status, :idle})
    assert {:ok, %Conversation{status: :idle}} = Store.get("s1")
  end

  test "list/1 returns decoded conversations newest first" do
    :ok =
      Store.save("a", %Metadata{agent_module: SomeAgent, parent_agent_id: nil, started_at: 1})

    :ok =
      Store.save("b", %Metadata{agent_module: OtherAgent, parent_agent_id: "a", started_at: 2})

    assert [
             %Conversation{
               agent_id: "b",
               metadata: %Metadata{
                 agent_module: OtherAgent,
                 parent_agent_id: "a",
                 started_at: 2
               }
             },
             %Conversation{
               agent_id: "a",
               metadata: %Metadata{
                 agent_module: SomeAgent,
                 parent_agent_id: nil,
                 started_at: 1
               }
             }
           ] = Store.list(10)

    assert [%Conversation{agent_id: "b"}] = Store.list(1)
  end

  test "get/1 returns decoded conversation, or :error when missing" do
    :ok = Store.save("a", %Metadata{agent_module: SomeAgent, parent_agent_id: nil, started_at: 1})

    assert {:ok, %Conversation{agent_id: "a", metadata: %Metadata{agent_module: SomeAgent}}} =
             Store.get("a")

    assert Store.get("missing") == :error
  end

  test "get/1 returns conversation with nil state when only metadata exists" do
    metadata = %Metadata{agent_module: SomeAgent, parent_agent_id: nil, started_at: 1}

    assert :ok = Store.save("started-only", metadata)
    assert {:ok, %Conversation{metadata: ^metadata, state: nil}} = Store.get("started-only")
  end

  test "get/1 returns conversation with nil metadata when only state exists" do
    state = %State{messages: [], bindings: [answer: 42]}

    assert :ok = Store.save("state-only", state)
    assert {:ok, %Conversation{metadata: nil, state: ^state}} = Store.get("state-only")
  end

  test "save/2 with Metadata does not reset an existing status" do
    metadata = %Metadata{agent_module: SomeAgent, parent_agent_id: nil, started_at: 1}

    assert :ok = Store.save("status-metadata", {:status, :running})
    assert :ok = Store.save("status-metadata", metadata)

    assert {:ok, %Conversation{status: :running, metadata: ^metadata}} =
             Store.get("status-metadata")
  end

  test "save/2 with Metadata preserves an existing parent on conflict" do
    metadata = %Metadata{agent_module: SomeAgent, parent_agent_id: "parent-1", started_at: 1}

    assert :ok = Store.save("child", metadata)
    assert :ok = Store.save("child", %{metadata | parent_agent_id: nil, started_at: 2})

    assert {:ok,
            %Conversation{
              metadata: %Metadata{parent_agent_id: "parent-1", started_at: 2}
            }} = Store.get("child")
  end

  test "list/1 includes state-only metadata-only and status-only conversations" do
    state = %State{messages: [], bindings: []}
    metadata = %Metadata{agent_module: SomeAgent, parent_agent_id: nil, started_at: 1}

    :ok = Store.save("state-only", state)
    :ok = Store.save("metadata-only", metadata)
    :ok = Store.save("status-only", {:status, :idle})

    assert [
             %Conversation{agent_id: "status-only", status: :idle, metadata: nil, state: nil},
             %Conversation{agent_id: "metadata-only", metadata: ^metadata, state: nil},
             %Conversation{agent_id: "state-only", metadata: nil, state: ^state}
           ] = Store.list(10)
  end

  test "save/2 returns :error for unsupported payloads" do
    assert :error = Store.save("bad-payload", %{messages: [], bindings: []})
    assert :error = Store.save("bad-status", {:status, :paused})
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

    CustomTableStore.get("user_42")

    assert_received {:sql,
                     "SELECT agent_id, agent_module, parent_agent_id, status, started_at, conversation_state FROM my_agents WHERE agent_id = $1"}
  end
end
