defmodule Legion.Sandbox.Popcorn do
  @moduledoc """
  Client-side Elixir evaluation in the user's browser via
  [Popcorn](https://popcorn.hexdocs.pm) - AtomVM compiled to WebAssembly.

  Unlike `Legion.Sandbox.Lua` and `Legion.Sandbox.Elixir`, the generated code
  never runs on the server: `execute/5` relays it to a browser session that
  registered as this agent's *host* (see `Legion.Sandbox.Popcorn.Host`) and
  blocks until the browser returns the result. Tool calls made by the code
  travel back over the same link and are applied on the server, in the
  Runner-spawned relay process - so Vault context, telemetry, and the
  `timeout_ms`/`limits` contract behave like the other sandboxes. The
  timeout covers the whole evaluation including the wait for a host to
  connect; `max_heap`/`max_reductions` bound only the server-side relay and
  tool work - they cannot reach into the browser VM.

  ## Bindings

  Variable state lives in the browser evaluator. The `bindings` term threaded
  through the executor is a small descriptor `%{session_id: id, binding_names:
  names}` - serialisable and checkpoint-safe, but pointing at state that dies
  with the page: after a reload the session starts fresh and the model
  recovers via undefined-variable errors.

  ## Requirements

  The agent must have an `:agent_id` (the sandbox routes by it), and the
  consuming application must run `{Legion, []}` in its supervision tree
  (which starts the `Legion.Sandbox.Popcorn.Host` registry), bridge a
  browser session to the registry, and serve the artifacts in `priv/popcorn`.

  ## Host protocol

  The registered host process receives
  `{:legion_sandbox_eval, eval_id, reply_to, payload}` where `payload` is
  `%{session_id, code, tools, timeout_ms}`, forwards it to the browser, and
  sends back `{:legion_sandbox_tool_call, eval_id, call}` for each tool call
  and finally `{:legion_sandbox_eval_result, eval_id, result}`. Tool replies
  arrive as `{:legion_sandbox_tool_reply, eval_id, call_id, result}`. Call
  and result maps use string keys (they cross a JSON boundary).
  """

  @behaviour Legion.Sandbox

  alias Legion.Sandbox.Popcorn.{Bridge, Host}
  alias Legion.Sandbox.Runner

  require EEx

  EEx.function_from_file(:defp, :constraints, Path.join(__DIR__, "popcorn/constraints.eex"))

  @max_code_size 64 * 1024

  @impl Legion.Sandbox
  def check(code, _tools) when not is_binary(code),
    do: {:error, "code must be a binary, got: #{inspect(code)}"}

  def check(code, _tools) when byte_size(code) > @max_code_size,
    do: {:error, "code exceeds maximum size of #{@max_code_size} bytes"}

  def check(code, _tools) do
    case Code.string_to_quoted(code) do
      {:ok, _ast} -> :ok
      {:error, error} -> {:error, format_syntax_error(error)}
    end
  end

  @impl Legion.Sandbox
  def binding_names(%{binding_names: names}), do: names
  def binding_names(_fresh), do: []

  @impl Legion.Sandbox
  def prompt_info do
    %{
      language: "Elixir",
      constraints: constraints(),
      tool_usage:
        "Each tool below is exposed as a module in the sandbox - call it as `ShortName.fun(...)`. " <>
          "The code runs in the visitor's browser and every tool call is relayed to the application, " <>
          "so batch work into as few calls as possible."
    }
  end

  @doc """
  Relays `code` to the browser session registered for the current agent.

  Blocks until the browser returns a result, serving the code's tool calls
  in the meantime, or until `timeout_ms` - which also covers waiting for a
  host to register at all. Returns `{:ok, {value, bindings_descriptor}}` or
  `{:error, reason}`.
  """
  @impl Legion.Sandbox
  def execute(code, timeout_ms, tools \\ [], bindings \\ [], limits \\ [])
      when is_binary(code) and is_list(tools) do
    with :ok <- check(code, tools) do
      run(code, timeout_ms, tools, bindings, limits)
    end
  end

  defp run(code, timeout_ms, tools, bindings, limits) do
    case Vault.get(:agent_id) do
      nil ->
        {:error,
         "#{inspect(__MODULE__)} requires an :agent_id - evaluations are routed to the " <>
           "browser session registered for the agent (see Legion.Sandbox.Popcorn.Host)"}

      agent_id ->
        session_id = session_id(bindings)

        payload = %{
          session_id: session_id,
          code: code,
          tools: Bridge.manifest(tools),
          timeout_ms: if(timeout_ms == :infinity, do: nil, else: timeout_ms)
        }

        module_refs = Bridge.module_refs(tools)

        Runner.run(
          fn -> relay(agent_id, payload, module_refs, session_id) end,
          timeout_ms,
          limits
        )
    end
  end

  defp session_id(%{session_id: id}), do: id
  defp session_id(_fresh), do: Base.url_encode64(:crypto.strong_rand_bytes(12))

  defp relay(agent_id, payload, module_refs, session_id) do
    host = Host.await(agent_id)
    eval_id = Base.url_encode64(:crypto.strong_rand_bytes(9))
    send(host, {:legion_sandbox_eval, eval_id, self(), payload})
    serve(host, eval_id, module_refs, session_id)
  end

  defp serve(host, eval_id, module_refs, session_id) do
    receive do
      {:legion_sandbox_tool_call, ^eval_id, call} ->
        send(
          host,
          {:legion_sandbox_tool_reply, eval_id, call_id(call), run_tool(module_refs, call)}
        )

        serve(host, eval_id, module_refs, session_id)

      {:legion_sandbox_eval_result, ^eval_id, %{"status" => "ok"} = result} ->
        value = result |> Map.get("value") |> Bridge.decode(module_refs)
        names = Map.get(result, "binding_names", [])
        {:ok, {value, %{session_id: session_id, binding_names: names}}}

      {:legion_sandbox_eval_result, ^eval_id, %{"status" => "error"} = result} ->
        {:error, Map.get(result, "message", "evaluation failed in the browser sandbox")}

      {:legion_sandbox_eval_result, ^eval_id, other} ->
        {:error, "malformed result from the browser sandbox: #{inspect(other)}"}
    end
  end

  defp call_id(%{"id" => id}), do: id
  defp call_id(_call), do: nil

  defp run_tool(module_refs, %{"tool" => tool_name, "fun" => fun_name, "args" => args})
       when is_binary(tool_name) and is_binary(fun_name) and is_list(args) do
    with {:ok, tool} <- fetch_tool(module_refs, tool_name),
         {:ok, fun} <- fetch_function(tool, fun_name, length(args)) do
      apply_tool(tool_name, tool, fun, Enum.map(args, &Bridge.decode(&1, module_refs)))
    else
      {:error, message} -> %{"status" => "error", "message" => message}
    end
  end

  defp run_tool(_module_refs, call),
    do: %{"status" => "error", "message" => "malformed tool call: #{inspect(call)}"}

  defp fetch_tool(module_refs, tool_name) do
    case Map.fetch(module_refs, tool_name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, "tool #{tool_name} is not available in this sandbox"}
    end
  end

  defp fetch_function(tool, fun_name, arity) do
    functions = Bridge.callable_functions(tool)

    with {:ok, fun} <- existing_atom(fun_name),
         true <- arity in Map.get(functions, fun, []) do
      {:ok, fun}
    else
      _ ->
        {:error,
         "#{Bridge.short_name(tool)}.#{fun_name}/#{arity} is not an available tool function"}
    end
  end

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  defp apply_tool(tool_name, tool, fun, args) do
    %{"status" => "ok", "value" => Bridge.encode(apply(tool, fun, args))}
  rescue
    e -> %{"status" => "error", "message" => "#{tool_name}.#{fun}: #{Exception.message(e)}"}
  catch
    :throw, value ->
      %{"status" => "error", "message" => "#{tool_name}.#{fun} threw: #{inspect(value)}"}

    :exit, reason ->
      %{"status" => "error", "message" => "#{tool_name}.#{fun} exited: #{inspect(reason)}"}
  end

  defp format_syntax_error({meta, message, token}) do
    line = if is_list(meta), do: Keyword.get(meta, :line), else: meta

    detail =
      case message do
        message when is_binary(message) -> message <> to_string(token)
        {opening, closing} -> to_string(opening) <> to_string(token) <> to_string(closing)
      end

    "syntax error on line #{line}: #{detail}"
  end
end
