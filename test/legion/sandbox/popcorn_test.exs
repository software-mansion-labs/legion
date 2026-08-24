defmodule Legion.Sandbox.PopcornTest do
  use ExUnit.Case, async: true

  alias Legion.Sandbox.Popcorn
  alias Legion.Test.FakePopcornHost
  alias Legion.Test.Support.EchoTool

  defp with_agent do
    agent_id = "popcorn-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(6))
    Vault.unsafe_put(:agent_id, agent_id)
    agent_id
  end

  describe "check/2" do
    test "accepts valid Elixir" do
      assert :ok = Popcorn.check("Enum.sum([1, 2, 3])", [])
    end

    test "rejects non-binary code" do
      assert {:error, message} = Popcorn.check(~c"1 + 1", [])
      assert message =~ "binary"
    end

    test "rejects oversized code" do
      assert {:error, message} = Popcorn.check(String.duplicate("a", 64 * 1024 + 1), [])
      assert message =~ "maximum size"
    end

    test "rejects syntax errors with a line number" do
      assert {:error, message} = Popcorn.check("1 +", [])
      assert message =~ "syntax error"
    end
  end

  describe "binding_names/1" do
    test "reads the descriptor and treats anything else as fresh" do
      assert Popcorn.binding_names(%{session_id: "s", binding_names: ["x", "y"]}) == ["x", "y"]
      assert Popcorn.binding_names([]) == []
    end
  end

  describe "prompt_info/0" do
    test "describes the browser-side Elixir environment" do
      info = Popcorn.prompt_info()
      assert info.language == "Elixir"
      assert info.constraints =~ "browser"
      assert info.tool_usage =~ "ShortName.fun"
    end
  end

  describe "execute/5" do
    test "requires an agent id" do
      assert {:error, message} = Popcorn.execute("1 + 1", 1_000)
      assert message =~ "agent_id"
    end

    test "evaluates through the registered host" do
      agent_id = with_agent()

      start_supervised!(
        {FakePopcornHost, agent_id: agent_id, handler: &FakePopcornHost.beam_eval_handler/2}
      )

      assert {:ok, {2, %{session_id: session_id, binding_names: []}}} =
               Popcorn.execute("1 + 1", 5_000)

      assert is_binary(session_id)
    end

    test "threads the session and binding names across evaluations" do
      agent_id = with_agent()
      test_pid = self()

      handler = fn payload, conn ->
        send(test_pid, {:payload, payload})
        FakePopcornHost.beam_eval_handler(payload, conn)
      end

      start_supervised!({FakePopcornHost, agent_id: agent_id, handler: handler})

      {:ok, {41, bindings}} = Popcorn.execute("x = 41", 5_000)
      assert %{session_id: session_id, binding_names: ["x"]} = bindings

      {:ok, {_value, %{session_id: ^session_id}}} = Popcorn.execute("1 + 1", 5_000, [], bindings)

      assert_receive {:payload, %{session_id: ^session_id, code: "x = 41"}}
      assert_receive {:payload, %{session_id: ^session_id, code: "1 + 1"}}
    end

    test "sends the tool manifest in the payload" do
      agent_id = with_agent()
      test_pid = self()

      handler = fn payload, conn ->
        send(test_pid, {:payload, payload})
        FakePopcornHost.beam_eval_handler(payload, conn)
      end

      start_supervised!({FakePopcornHost, agent_id: agent_id, handler: handler})
      {:ok, _result} = Popcorn.execute("1", 5_000, [EchoTool])

      assert_receive {:payload, %{tools: [%{name: "EchoTool", functions: functions}]}}
      assert %{name: "add", arities: [2]} in functions
    end

    test "serves tool calls during the evaluation" do
      agent_id = with_agent()

      handler = fn _payload, conn ->
        reply =
          conn.call_tool.(%{"id" => 1, "tool" => "EchoTool", "fun" => "add", "args" => [20, 22]})

        %{"status" => "ok", "value" => reply["value"], "binding_names" => []}
      end

      start_supervised!({FakePopcornHost, agent_id: agent_id, handler: handler})
      assert {:ok, {42, _bindings}} = Popcorn.execute("EchoTool.add(20, 22)", 5_000, [EchoTool])
    end

    test "tool results are JSON-encoded like the Lua bridge" do
      agent_id = with_agent()

      handler = fn _payload, conn ->
        reply =
          conn.call_tool.(%{
            "id" => 1,
            "tool" => "EchoTool",
            "fun" => "echo",
            "args" => [%{"msg" => "hi"}]
          })

        %{"status" => "ok", "value" => reply, "binding_names" => []}
      end

      start_supervised!({FakePopcornHost, agent_id: agent_id, handler: handler})

      {:ok, {value, _bindings}} =
        Popcorn.execute("EchoTool.echo(%{msg: \"hi\"})", 5_000, [EchoTool])

      assert value == %{"status" => "ok", "value" => ["ok", %{"msg" => "hi"}]}
    end

    test "rejects tool calls outside the allowed surface" do
      agent_id = with_agent()

      handler = fn _payload, conn ->
        unknown_tool =
          conn.call_tool.(%{"id" => 1, "tool" => "System", "fun" => "cmd", "args" => []})

        unknown_fun =
          conn.call_tool.(%{
            "id" => 2,
            "tool" => "EchoTool",
            "fun" => "description",
            "args" => []
          })

        bad_arity =
          conn.call_tool.(%{"id" => 3, "tool" => "EchoTool", "fun" => "add", "args" => [1]})

        %{
          "status" => "ok",
          "value" => [unknown_tool, unknown_fun, bad_arity],
          "binding_names" => []
        }
      end

      start_supervised!({FakePopcornHost, agent_id: agent_id, handler: handler})
      {:ok, {[t, f, a], _bindings}} = Popcorn.execute("1", 5_000, [EchoTool])
      assert %{"status" => "error"} = t
      assert %{"status" => "error"} = f
      assert %{"status" => "error"} = a
    end

    test "tool exceptions come back as error results, not crashes" do
      agent_id = with_agent()

      handler = fn _payload, conn ->
        reply = conn.call_tool.(%{"id" => 1, "tool" => "EchoTool", "fun" => "boom", "args" => []})
        %{"status" => "ok", "value" => reply, "binding_names" => []}
      end

      start_supervised!({FakePopcornHost, agent_id: agent_id, handler: handler})
      {:ok, {value, _bindings}} = Popcorn.execute("EchoTool.boom()", 5_000, [EchoTool])
      assert %{"status" => "error", "message" => message} = value
      assert message =~ "boom"
    end

    test "browser-side errors surface as {:error, message}" do
      agent_id = with_agent()

      handler = fn _payload, _conn ->
        %{"status" => "error", "message" => "undefined function frob/0"}
      end

      start_supervised!({FakePopcornHost, agent_id: agent_id, handler: handler})

      assert {:error, "undefined function frob/0"} = Popcorn.execute("frob()", 5_000)
    end

    test "no registered host runs into the sandbox timeout" do
      _agent_id = with_agent()
      assert {:error, :timeout} = Popcorn.execute("1 + 1", 300)
    end

    test "a host that never answers runs into the sandbox timeout" do
      agent_id = with_agent()
      handler = fn _payload, _conn -> Process.sleep(:infinity) end
      start_supervised!({FakePopcornHost, agent_id: agent_id, handler: handler})

      assert {:error, :timeout} = Popcorn.execute("1 + 1", 300)
    end
  end
end
