defmodule Legion.EvalGuardTest do
  use ExUnit.Case, async: true

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

  test "a denial emits telemetry carrying the code and reason" do
    :telemetry.attach(
      "guard-denied-test",
      [:legion, :eval_guard, :denied],
      fn event, _measurements, metadata, pid -> send(pid, {:telemetry, event, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("guard-denied-test") end)

    Legion.EvalGuard.check(DenyEverything, "Shop.checkout()", @context)

    assert_receive {:telemetry, [:legion, :eval_guard, :denied], metadata}
    assert metadata.guard == DenyEverything
    assert metadata.code == "Shop.checkout()"
    assert metadata.reason =~ "renovations"
  end

  test "the guard receives the code and the agent context" do
    Legion.EvalGuard.check(RecordContext, "Shop.list_records()", @context)

    assert_receive {:checked, "Shop.list_records()", context}
    assert context.agent == SomeAgent
    assert context.agent_id == "conversation-1"
    assert context.tools == [SomeTool]
  end
end
