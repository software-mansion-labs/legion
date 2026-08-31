defmodule Legion.EvalGuardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defmodule DenyEverything do
    @behaviour Legion.EvalGuard

    @impl true
    def check(_code, _context), do: {:deny, "the shop is closed for renovations"}
  end

  defmodule AllowEverything do
    @behaviour Legion.EvalGuard

    @impl true
    def check(_code, _context), do: :allow
  end

  defmodule RecordContext do
    @behaviour Legion.EvalGuard

    @impl true
    def check(code, context) do
      send(self(), {:checked, code, context})
      :allow
    end
  end

  @context %{agent: SomeAgent, agent_id: "conversation-1", tools: [SomeTool]}

  test "no guard configured allows everything" do
    assert Legion.EvalGuard.check(nil, "System.halt()", @context) == :allow
  end

  test "an allowing guard passes the code through" do
    assert Legion.EvalGuard.check(AllowEverything, "1 + 1", @context) == :allow
  end

  test "a denying guard returns its reason" do
    assert {:deny, reason} = Legion.EvalGuard.check(DenyEverything, "1 + 1", @context)
    assert reason =~ "renovations"
  end

  @tag capture_log: true
  test "a denial emits telemetry carrying the code and reason" do
    :telemetry.attach(
      "guard-denied-test",
      [:legion, :eval_guard, :denied],
      fn event, _measurements, metadata, pid -> send(pid, {:telemetry, event, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("guard-denied-test") end)

    Legion.EvalGuard.check(DenyEverything, "Shop.checkout()", @context)

    # The handler is global, so denials from concurrently running tests also
    # land in this mailbox - match on this test's own guard.
    assert_receive {:telemetry, [:legion, :eval_guard, :denied],
                    %{guard: DenyEverything} = metadata}

    assert metadata.code == "Shop.checkout()"
    assert metadata.reason =~ "renovations"
  end

  defmodule Broken do
    @behaviour Legion.EvalGuard

    @impl true
    def check("raise", _context), do: raise("the reviewer is on fire")
    def check("throw", _context), do: throw(:nope)
    def check("exit", _context), do: exit(:shutdown)
    def check("garbage", _context), do: :maybe
  end

  test "a guard that raises denies rather than taking the caller down" do
    log =
      capture_log(fn ->
        assert {:deny, reason} = Legion.EvalGuard.check(Broken, "raise", @context)
        assert reason =~ "the reviewer is on fire"
      end)

    assert log =~ "[error]"
    assert log =~ "Broken failed to return a verdict"
  end

  @tag capture_log: true
  test "a guard that throws or exits denies" do
    assert {:deny, thrown} = Legion.EvalGuard.check(Broken, "throw", @context)
    assert thrown =~ ":nope"

    assert {:deny, exited} = Legion.EvalGuard.check(Broken, "exit", @context)
    assert exited =~ ":shutdown"
  end

  @tag capture_log: true
  test "a guard returning something that is not a verdict denies" do
    assert {:deny, reason} = Legion.EvalGuard.check(Broken, "garbage", @context)
    assert reason =~ ":maybe"
  end

  test "the guard receives the code and the agent context" do
    Legion.EvalGuard.check(RecordContext, "Shop.list_records()", @context)

    assert_receive {:checked, "Shop.list_records()", context}
    assert context.agent == SomeAgent
    assert context.agent_id == "conversation-1"
    assert context.tools == [SomeTool]
  end
end
