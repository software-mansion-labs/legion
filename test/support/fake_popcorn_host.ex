defmodule Legion.Test.FakePopcornHost do
  @moduledoc """
  Stands in for the browser side of `Legion.Sandbox.Popcorn` in tests.

  Registers itself as the host for an agent id and answers the sandbox's
  eval protocol with whatever the test's `handler` returns. The handler
  receives the eval payload and a `conn` map whose `:call_tool` function
  performs a full tool round trip through the sandbox relay (send
  `:legion_sandbox_tool_call`, wait for `:legion_sandbox_tool_reply`).
  """
  use GenServer

  alias Legion.Sandbox.Popcorn.Bridge
  alias Legion.Sandbox.Popcorn.Host

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Handler that mimics the browser evaluator using the host BEAM."
  def beam_eval_handler(payload, _conn) do
    {value, bindings} = Code.eval_string(payload.code, [])

    %{
      "status" => "ok",
      # Jason round trip mirrors the real JSON boundary's lossiness.
      "value" => value |> Bridge.encode() |> Jason.encode!() |> Jason.decode!(),
      "binding_names" => Enum.map(bindings, fn {name, _value} -> Atom.to_string(name) end)
    }
  rescue
    e -> %{"status" => "error", "message" => Exception.message(e)}
  end

  @impl GenServer
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    handler = Keyword.fetch!(opts, :handler)
    :ok = Host.register(agent_id)
    {:ok, %{handler: handler}}
  end

  @impl GenServer
  def handle_info({:legion_sandbox_eval, eval_id, from, payload}, state) do
    conn = %{
      eval_id: eval_id,
      call_tool: fn call ->
        send(from, {:legion_sandbox_tool_call, eval_id, call})

        receive do
          {:legion_sandbox_tool_reply, ^eval_id, _call_id, result} -> result
        after
          1_000 -> raise "sandbox did not reply to tool call"
        end
      end
    }

    send(from, {:legion_sandbox_eval_result, eval_id, state.handler.(payload, conn)})
    {:noreply, state}
  end
end
