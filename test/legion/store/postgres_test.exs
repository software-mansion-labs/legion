defmodule Legion.Store.PostgresTest do
  use ExUnit.Case, async: true

  defmodule FakeRepo do
    @moduledoc "Emulates repo.query!/2 for the statements the store issues."

    def start_link, do: Agent.start_link(fn -> %{snapshots: %{}, runs: %{}} end, name: __MODULE__)

    def query!("SELECT snapshot FROM " <> _rest, [agent_id]) do
      Agent.get(__MODULE__, fn state ->
        case {state.snapshots, state.runs} do
          {%{^agent_id => snapshot}, _runs} -> %{rows: [[snapshot]]}
          {_snapshots, %{^agent_id => _run}} -> %{rows: [[nil]]}
          _neither -> %{rows: []}
        end
      end)
    end

    def query!("INSERT INTO " <> _rest, [agent_id, snapshot]) do
      Agent.update(__MODULE__, &put_in(&1.snapshots[agent_id], snapshot))
      %{num_rows: 1}
    end

    def query!("INSERT INTO " <> _rest, [agent_id, agent_module, parent_agent_id, pid, started_at]) do
      Agent.update(
        __MODULE__,
        &put_in(&1.runs[agent_id], %{
          agent_module: agent_module,
          parent_agent_id: parent_agent_id,
          pid: pid,
          status: "idle",
          started_at: started_at
        })
      )

      %{num_rows: 1}
    end

    def query!("UPDATE " <> _rest, [agent_id, status]) do
      Agent.update(__MODULE__, &put_in(&1.runs[agent_id].status, status))
      %{num_rows: 1}
    end

    def query!("SELECT agent_id" <> _rest = sql, [param]) do
      rows =
        Agent.get(__MODULE__, fn state ->
          for {agent_id, run} <- state.runs do
            [agent_id, run.agent_module, run.parent_agent_id, run.pid, run.status, run.started_at]
          end
        end)

      if String.contains?(sql, "WHERE agent_id") do
        %{rows: Enum.filter(rows, fn [agent_id | _rest] -> agent_id == param end)}
      else
        %{rows: rows |> Enum.sort_by(&List.last/1, :desc) |> Enum.take(param)}
      end
    end

    def run(agent_id), do: Agent.get(__MODULE__, & &1.runs[agent_id])
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

  test "save_run/2 stores the module in inspect form with parent, pid, and start time" do
    metadata = %{
      agent_module: Legion.Test.Support.MathAgent,
      parent_agent_id: "p1",
      pid: self(),
      started_at: 123
    }

    assert :ok = Store.save_run("user_42", metadata)

    assert FakeRepo.run("user_42") == %{
             agent_module: "Legion.Test.Support.MathAgent",
             parent_agent_id: "p1",
             pid: :erlang.term_to_binary(self()),
             status: "idle",
             started_at: 123
           }
  end

  test "save_status/2 flips the run status and get_run/1 decodes it" do
    :ok = Store.save_run("s1", %{agent_module: SomeAgent, parent_agent_id: nil, started_at: 1})
    assert %{status: :idle} = Store.get_run("s1")

    :ok = Store.save_status("s1", :running)
    assert %{status: :running} = Store.get_run("s1")

    :ok = Store.save_status("s1", :idle)
    assert %{status: :idle} = Store.get_run("s1")
  end

  test "get_run/1 round-trips the pid" do
    metadata = %{
      agent_module: SomeAgent,
      parent_agent_id: nil,
      pid: self(),
      started_at: 123
    }

    :ok = Store.save_run("with-pid", metadata)

    assert %{pid: pid} = Store.get_run("with-pid")
    assert pid == self()
  end

  test "list_runs/1 returns decoded runs newest first" do
    :ok = Store.save_run("a", %{agent_module: SomeAgent, parent_agent_id: nil, started_at: 1})
    :ok = Store.save_run("b", %{agent_module: OtherAgent, parent_agent_id: "a", started_at: 2})

    assert [
             %{agent_id: "b", agent_module: OtherAgent, parent_agent_id: "a", started_at: 2},
             %{agent_id: "a", agent_module: SomeAgent, parent_agent_id: nil, started_at: 1}
           ] = Store.list_runs(10)

    assert [%{agent_id: "b"}] = Store.list_runs(1)
  end

  test "get_run/1 returns the decoded run, or nil when missing" do
    :ok = Store.save_run("a", %{agent_module: SomeAgent, parent_agent_id: nil, started_at: 1})

    assert %{agent_id: "a", agent_module: SomeAgent} = Store.get_run("a")
    assert Store.get_run("missing") == nil
  end

  test "load/1 returns :error when only run metadata exists (snapshot still null)" do
    metadata = %{agent_module: SomeAgent, parent_agent_id: nil, started_at: 1}

    assert :ok = Store.save_run("started-only", metadata)
    assert :error = Store.load("started-only")
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
