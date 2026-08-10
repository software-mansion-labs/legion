defmodule Legion.Integration.EvalGuardTest do
  @moduledoc """
  Integration test: confirm `Legion.EvalGuard.LLM` vets generated code with a
  real model, on the executor's path.

  Skipped by default to avoid external API calls and LLM costs.
  Run with:

      mix test test/integration/eval_guard_test.exs --include integration
  """
  use ExUnit.Case, async: true

  alias Legion.Test.Support.MathTool

  @moduletag :integration
  @moduletag timeout: 120_000

  defmodule GuardedMathAgent do
    @moduledoc "A math agent whose code is reviewed before it runs."
    use Legion.Agent

    defmodule NoRandomAdd do
      @moduledoc "Denies the one tool function the agent is asked to call."
      use Legion.EvalGuard.LLM,
        policy: """
        Deny any code that calls random_add. Allow everything else, including
        plain arithmetic.
        """
    end

    def tools, do: [MathTool]
    def config, do: %{eval_guard: NoRandomAdd, max_iterations: 3, max_retries: 1}
  end

  setup context do
    unless System.get_env("OPENAI_API_KEY"), do: raise("OPENAI_API_KEY not set")

    test_pid = self()
    handler_id = {__MODULE__, context.test}

    :telemetry.attach(
      handler_id,
      [:legion, :eval_guard, :denied],
      fn _event, _measurements, metadata, _config ->
        # Other tests in the suite emit the same global event concurrently;
        # only this agent's guard is relevant here.
        if metadata.guard == GuardedMathAgent.NoRandomAdd do
          send(test_pid, {:denied, metadata.reason})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "the model denies code the policy forbids" do
    Legion.execute(GuardedMathAgent, "Call MathTool.random_add(2, 3) and return it.")

    assert_received {:denied, reason}
    assert reason =~ "random_add"
  end

  test "code the policy allows runs" do
    assert {:ok, result} =
             Legion.execute(GuardedMathAgent, "What is 21 + 21? Compute it and return it.")

    assert result =~ "42"
    refute_received {:denied, _reason}
  end
end
