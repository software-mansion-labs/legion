defmodule LegionPopcornClient.Evaluator do
  @moduledoc false
  # Runs inside AtomVM in the browser. Receives eval requests from JS
  # (`popcorn.call(["eval", session_id, code, manifest])` targeting
  # :legion_popcorn), evaluates them in a spawned worker, and keeps each
  # session's bindings for the lifetime of the page.
  use GenServer

  alias Popcorn.Wasm
  require Popcorn.Wasm

  @process_name :legion_popcorn

  def start_link(_args), do: GenServer.start_link(__MODULE__, nil, name: @process_name)

  @impl GenServer
  def init(_arg) do
    :application.set_env(:elixir, :ansi_enabled, false)
    Wasm.ready(@process_name)
    {:ok, %{sessions: %{}, worker: nil, defined: %{}}}
  end

  @impl GenServer
  def handle_info(raw_msg, state) when Wasm.is_wasm_message(raw_msg) do
    case Wasm.parse_message!(raw_msg) do
      {:wasm_call, ["eval", session_id, code, manifest], promise} ->
        {:noreply, start_eval(session_id, code, manifest, promise, state)}

      {:wasm_cast, ["cancel", _session_id]} ->
        {:noreply, cancel_worker(state)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:eval_done, worker, session_id, result, bindings}, state) do
    case state.worker do
      {^worker, promise, ref} ->
        Process.demonitor(ref, [:flush])
        Wasm.resolve(result, promise)

        {:noreply,
         %{state | sessions: Map.put(state.sessions, session_id, bindings), worker: nil}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{worker: {pid, promise, ref}} = state) do
    Wasm.resolve(%{status: "error", message: "evaluation crashed: #{inspect(reason)}"}, promise)
    {:noreply, %{state | worker: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_eval(session_id, code, manifest, promise, %{worker: nil} = state) do
    state = ensure_stubs(manifest, state)
    bindings = Map.get(state.sessions, session_id, [])
    parent = self()
    {pid, ref} = spawn_monitor(fn -> run_eval(parent, session_id, code, manifest, bindings) end)
    %{state | worker: {pid, promise, ref}}
  end

  defp start_eval(_session_id, _code, _manifest, promise, state) do
    Wasm.resolve(
      %{status: "error", message: "evaluator is busy with another evaluation"},
      promise
    )

    state
  end

  # Defines (or redefines, when the tool surface changed) one stub module per
  # manifest entry. Every stub function relays to ToolBridge.call/3.
  defp ensure_stubs(manifest, state) do
    defined =
      for %{"name" => name, "functions" => functions} = entry <- manifest,
          Map.get(state.defined, name) != functions,
          reduce: state.defined do
        defined ->
          define_stub(entry)
          Map.put(defined, name, functions)
      end

    %{state | defined: defined}
  end

  defp define_stub(%{"name" => name, "functions" => functions}) do
    funs =
      for %{"name" => fun, "arities" => arities} <- functions, arity <- arities do
        vars = Enum.map_join(1..arity//1, ", ", &"a#{&1}")

        "def #{fun}(#{vars}), " <>
          "do: LegionPopcornClient.ToolBridge.call(\"#{name}\", \"#{fun}\", [#{vars}])"
      end

    code = """
    defmodule #{name} do
      #{Enum.join(funs, "\n  ")}
    end
    """

    Code.eval_string(code)
  end

  defp cancel_worker(%{worker: nil} = state), do: state

  defp cancel_worker(%{worker: {pid, promise, ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    Wasm.resolve(%{status: "error", message: "evaluation cancelled"}, promise)
    %{state | worker: nil}
  end

  @worker_name :legion_popcorn_worker

  defp run_eval(parent, session_id, code, manifest, bindings) do
    Process.register(self(), @worker_name)
    LegionPopcornClient.ToolBridge.put_manifest(manifest)
    {value, new_bindings} = Code.eval_string(code, bindings)

    result = %{
      status: "ok",
      value: LegionPopcornClient.ToolBridge.json_safe(value),
      binding_names: Enum.map(new_bindings, &binding_name/1)
    }

    send(parent, {:eval_done, self(), session_id, result, new_bindings})
  rescue
    e ->
      message = Exception.format(:error, e, __STACKTRACE__)

      send(
        parent,
        {:eval_done, self(), session_id, %{status: "error", message: message}, bindings}
      )
  catch
    kind, value ->
      message = "#{kind}: #{inspect(value)}"

      send(
        parent,
        {:eval_done, self(), session_id, %{status: "error", message: message}, bindings}
      )
  end

  defp binding_name({{name, _context}, _value}), do: Atom.to_string(name)
  defp binding_name({name, _value}), do: Atom.to_string(name)
end
