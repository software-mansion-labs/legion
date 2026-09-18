defmodule Legion.MCP do
  @moduledoc """
  Speaks the Model Context Protocol for a running agent: a JSON-RPC message in,
  a JSON-RPC response out.

  An MCP host brings its own model. That model writes code, and the server runs
  it with `Legion.eval/3` in an agent whose tools, sandbox and instructions are
  the agent's own. The host's model does the thinking, so the agent makes no
  LLM request of its own; what a call costs is one evaluation.

  The server exposes one tool, `repl`, taking the code to run. The agent's
  system prompt in MCP mode becomes the server `instructions`, so the host's
  model reads the same description of the language, the tools and the variable
  scope that Legion's own loop would.

  `handle/3` is transport-agnostic. `Legion.MCP.Plug` serves it over Streamable
  HTTP; anything that can deliver a decoded JSON-RPC map can drive it. Requests
  return a response map, notifications return `nil`.

  ## Sessions are agents

  Every MCP session is a regular agent process, started with the options
  `Legion.start_link/2` takes and looked up by its agent id. Whatever makes an
  agent persist, resume, be rate limited or hand context to its tools works
  the same for a session:

    - With a store and a stable `:agent_id`, a session continues the stored
      conversation: variables and history included. Every `repl` call is saved
      as a step, the code as an `:assistant` message followed by its
      `:eval_result` or `:error`.
    - With rate limit rules, every call is checked before it runs. A denied
      call runs nothing and comes back as a tool error the model can read.
    - Two sessions that resolve to one agent id share one process, so their
      calls are serialised and nothing is overwritten.

  Sessions started by this module run under `Legion.AgentSupervisor`. Give
  them an `:idle_timeout` so an agent nobody talks to stops and frees its
  memory; the store keeps its state for the next call.
  """

  alias Legion.{AgentPrompt, AgentServer}

  @protocol_versions ~w(2025-06-18 2025-03-26 2024-11-05)

  @tool %{
    "name" => "repl",
    "description" =>
      "Execute code in this server's sandbox. The language, its rules and the tool " <>
        "modules you can call are described in the server instructions. Variables persist " <>
        "across calls within this session unless the instructions say otherwise.",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{
        "code" => %{"type" => "string", "description" => "Code to execute in the sandbox"}
      },
      "required" => ["code"]
    }
  }

  @doc """
  Answers one JSON-RPC `message` for the agent process `agent`.

  `opts` must hold `:agent`, the agent module, and `:name` and `:version` for
  `serverInfo`. Returns the response map for a request, or `nil` for a
  notification or a response, which need no answer.

  Supported methods: `initialize`, `ping`, `tools/list` and `tools/call` of
  the `repl` tool. Anything else is a `-32_601` error.
  """
  def handle(%{"method" => method, "id" => id} = message, agent, opts) when is_binary(method) do
    case dispatch(method, Map.get(message, "params") || %{}, agent, opts) do
      {:ok, result} ->
        %{"jsonrpc" => "2.0", "id" => id, "result" => result}

      {:error, code, text} ->
        %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => text}}
    end
  end

  def handle(%{"method" => method}, _agent, _opts) when is_binary(method), do: nil
  def handle(%{"id" => _id}, _agent, _opts), do: nil

  def handle(_message, _agent, _opts) do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32_600, "message" => "Invalid Request"}
    }
  end

  @doc """
  Returns the pid of the agent for `opts`, starting `agent_module` under
  `Legion.AgentSupervisor` with those options when no live process owns the
  agent id. Without an `:agent_id`, a new agent starts every time.

  `Legion` must be running in the supervision tree.
  """
  def agent(agent_module, opts) do
    child = %{
      id: AgentServer,
      start: {AgentServer, :start_link, [agent_module, opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(Legion.AgentSupervisor, child) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, reason} -> raise "could not start #{inspect(agent_module)}: #{inspect(reason)}"
    end
  end

  defp dispatch("initialize", params, agent, opts) do
    requested = params["protocolVersion"]
    version = if requested in @protocol_versions, do: requested, else: hd(@protocol_versions)
    config = AgentServer.get_config(agent)

    {:ok,
     %{
       "protocolVersion" => version,
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => opts[:name], "version" => opts[:version]},
       "instructions" => AgentPrompt.system_prompt(opts[:agent], config, mode: :mcp)
     }}
  end

  defp dispatch("ping", _params, _agent, _opts), do: {:ok, %{}}

  defp dispatch("tools/list", _params, _agent, _opts), do: {:ok, %{"tools" => [@tool]}}

  defp dispatch("tools/call", %{"name" => "repl", "arguments" => %{"code" => code}}, agent, _opts)
       when is_binary(code) do
    {error?, text} =
      case Legion.eval(agent, code) do
        {:ok, text} -> {false, text}
        {:error, text} -> {true, text}
        {:cancel, {:rate_limited, violations}} -> {true, rate_limited(violations)}
      end

    {:ok, %{"content" => [%{"type" => "text", "text" => text}], "isError" => error?}}
  end

  defp dispatch("tools/call", %{"name" => "repl"}, _agent, _opts),
    do: {:error, -32_602, "repl takes a string argument: code"}

  defp dispatch("tools/call", params, _agent, _opts),
    do: {:error, -32_602, "Unknown tool: #{inspect(params["name"])}"}

  defp dispatch(method, _params, _agent, _opts),
    do: {:error, -32_601, "Method not found: #{method}"}

  defp rate_limited(violations),
    do: "Rate limit exceeded (#{Enum.join(violations, ", ")}). Try again later."
end
