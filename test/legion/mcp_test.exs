defmodule Legion.MCPTest do
  # Agents started through `Legion.MCP.agent/2` share one named supervisor.
  use ExUnit.Case, async: false

  alias Legion.MCP
  alias Legion.RateLimiter.{ExceededError, Policy, Rule}
  alias Legion.Store.Payload
  alias Legion.Test.Support.{MathAgent, MathTool, MemoryStore}

  @opts [agent: MathAgent, name: "math", version: "1.2.3"]

  defmodule ConfiguredAgent do
    @moduledoc "Agent with per-call variables."
    use Legion.Agent

    def tools, do: [MathTool]
    def config, do: %{binding_scope: :iteration}
  end

  defmodule CustomPromptAgent do
    @moduledoc "Agent with a hand-written prompt."
    use Legion.Agent

    def system_prompt, do: "Do exactly as I say."
  end

  defmodule DenyingLimiter do
    @moduledoc "Denies every call."
    @behaviour Legion.RateLimiter

    @impl Legion.RateLimiter
    def enforce!(agent_id, [%Rule{} = rule]) do
      raise ExceededError,
        agent_id: agent_id,
        identity: rule.identity,
        policy: rule.policy,
        usage: %{agents: 1, tokens: nil, evals: 30},
        violations: [:max_evals]
    end
  end

  setup do
    start_supervised!(MemoryStore)
    start_supervised!({DynamicSupervisor, name: Legion.AgentSupervisor, strategy: :one_for_one})

    {:ok, agent} = Legion.start_link(MathAgent)
    %{agent: agent}
  end

  defp request(method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params}
  end

  defp initialize(agent, opts \\ @opts, version \\ "2025-03-26") do
    params = %{"protocolVersion" => version, "capabilities" => %{}, "clientInfo" => %{}}
    %{"result" => result} = MCP.handle(request("initialize", params), agent, opts)
    result
  end

  defp call(agent, code) do
    params = %{"name" => "repl", "arguments" => %{"code" => code}}
    MCP.handle(request("tools/call", params), agent, @opts)
  end

  defp repl(agent, code) do
    %{"result" => %{"content" => [%{"type" => "text", "text" => text}], "isError" => error?}} =
      call(agent, code)

    {error?, text}
  end

  describe "initialize" do
    test "answers with the server info, the protocol version asked for and the instructions",
         %{agent: agent} do
      result = initialize(agent)

      assert result["serverInfo"] == %{"name" => "math", "version" => "1.2.3"}
      assert result["protocolVersion"] == "2025-03-26"
      assert result["capabilities"] == %{"tools" => %{}}
      assert result["instructions"] =~ "An agent that does math."
      assert result["instructions"] =~ "MathTool"
      assert result["instructions"] =~ "Lua"
      assert result["instructions"] =~ "`repl`"
    end

    test "falls back to the latest protocol version it knows", %{agent: agent} do
      assert initialize(agent, @opts, "1999-01-01")["protocolVersion"] == "2025-06-18"
    end

    test "the instructions tell the model how long variables live", %{agent: agent} do
      assert initialize(agent)["instructions"] =~ "Variables persist"

      {:ok, configured} = Legion.start_link(ConfiguredAgent)
      opts = Keyword.put(@opts, :agent, ConfiguredAgent)
      assert initialize(configured, opts)["instructions"] =~ "Variables do not persist"
    end

    test "an agent's own system_prompt/0 is the instructions" do
      {:ok, custom} = Legion.start_link(CustomPromptAgent)
      opts = Keyword.put(@opts, :agent, CustomPromptAgent)

      assert initialize(custom, opts)["instructions"] == "Do exactly as I say."
    end
  end

  describe "tools" do
    test "ping answers with an empty result", %{agent: agent} do
      assert %{"id" => 7, "result" => %{}} = MCP.handle(request("ping"), agent, @opts)
    end

    test "lists exactly one tool, repl, taking the code to run", %{agent: agent} do
      %{"result" => %{"tools" => [tool]}} = MCP.handle(request("tools/list"), agent, @opts)

      assert tool["name"] == "repl"
      assert tool["inputSchema"]["required"] == ["code"]
      assert tool["description"] =~ "sandbox"
    end

    test "repl runs the code and keeps variables between calls", %{agent: agent} do
      assert {false, _text} = repl(agent, "x = MathTool.random_add(1, 0)")
      assert {false, text} = repl(agent, "return x + 1")

      assert text =~ "984"
      assert text =~ "Available variables: `x`"
    end

    test "a sandbox error is a tool error", %{agent: agent} do
      assert {true, text} = repl(agent, "return (")
      assert text != ""
    end

    test "a rate-limited call is a tool error and runs nothing" do
      rule = %Rule{identity: %{"user" => "u"}, policy: %Policy{window_ms: 1_000, max_evals: 30}}

      {:ok, denied} =
        Legion.start_link(MathAgent,
          store: MemoryStore,
          agent_id: "mcp-denied",
          rate_limit: [limiter: DenyingLimiter, rules: [rule]]
        )

      assert {true, "Rate limit exceeded (max_evals). Try again later."} =
               repl(denied, "return 1")

      assert {:ok, %Payload{conversation_state: nil}} = MemoryStore.get("mcp-denied")
    end

    test "an unknown tool, or repl without code, is an invalid params error", %{agent: agent} do
      params = %{"name" => "shell", "arguments" => %{}}

      assert %{"error" => %{"code" => -32_602}} =
               MCP.handle(request("tools/call", params), agent, @opts)

      params = %{"name" => "repl", "arguments" => %{"code" => 1}}

      assert %{"error" => %{"code" => -32_602}} =
               MCP.handle(request("tools/call", params), agent, @opts)
    end
  end

  describe "protocol" do
    test "an unknown method is a method not found error", %{agent: agent} do
      assert %{"id" => 7, "error" => %{"code" => -32_601, "message" => message}} =
               MCP.handle(request("resources/list"), agent, @opts)

      assert message =~ "resources/list"
    end

    test "a notification needs no answer", %{agent: agent} do
      message = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert MCP.handle(message, agent, @opts) == nil
    end

    test "a response needs no answer", %{agent: agent} do
      assert MCP.handle(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}, agent, @opts) == nil
    end

    test "anything else is an invalid request", %{agent: agent} do
      assert %{"id" => nil, "error" => %{"code" => -32_600}} =
               MCP.handle(%{"x" => 1}, agent, @opts)

      assert %{"id" => nil, "error" => %{"code" => -32_600}} = MCP.handle([], agent, @opts)
    end
  end

  describe "agent/2" do
    test "starts the agent under Legion.AgentSupervisor and finds it again by its id" do
      opts = [store: MemoryStore, agent_id: "mcp-shared"]
      pid = MCP.agent(MathAgent, opts)

      assert MCP.agent(MathAgent, opts) == pid
      assert {:ok, ^pid} = Legion.lookup("mcp-shared")

      children = DynamicSupervisor.which_children(Legion.AgentSupervisor)
      assert Enum.any?(children, &match?({_id, ^pid, :worker, _modules}, &1))
    end

    test "without an agent id every call starts an agent of its own" do
      assert MCP.agent(MathAgent, []) != MCP.agent(MathAgent, [])
    end
  end
end
