defmodule Legion.MCP.PlugTest do
  # Agents started by the plug share one named supervisor, and one test binds a port.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Legion.MCP
  alias Legion.Test.Support.{MathAgent, MemoryStore}

  setup do
    start_supervised!(MemoryStore)
    start_supervised!({DynamicSupervisor, name: Legion.AgentSupervisor, strategy: :one_for_one})
    :ok
  end

  defp opts(overrides \\ []) do
    MCP.Plug.init(Keyword.merge([agent: MathAgent, name: "math", version: "1.0.0"], overrides))
  end

  defp request(method, params) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
  end

  defp post(body, headers \\ [], opts \\ opts()) do
    body = if is_binary(body), do: body, else: Jason.encode!(body)

    conn = put_req_header(conn(:post, "/", body), "content-type", "application/json")

    headers
    |> Enum.reduce(conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)
    |> MCP.Plug.call(opts)
  end

  defp initialize(opts \\ opts()) do
    params = %{"protocolVersion" => "2025-06-18", "capabilities" => %{}, "clientInfo" => %{}}
    post(request("initialize", params), [], opts)
  end

  defp repl(session_id, code, opts \\ opts()) do
    params = %{"name" => "repl", "arguments" => %{"code" => code}}
    headers = if session_id, do: [{"mcp-session-id", session_id}], else: []
    conn = post(request("tools/call", params), headers, opts)

    %{"result" => %{"content" => [%{"text" => text}], "isError" => error?}} = body(conn)
    {error?, text}
  end

  defp session_id(conn), do: conn |> get_resp_header("mcp-session-id") |> List.first()
  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "anonymous sessions" do
    test "initialize starts an agent and hands back its id as the session id" do
      conn = initialize()

      assert conn.status == 200
      assert body(conn)["result"]["serverInfo"] == %{"name" => "math", "version" => "1.0.0"}
      assert {:ok, _pid} = Legion.lookup(session_id(conn))
    end

    test "a session keeps its variables across requests" do
      session = session_id(initialize())

      assert {false, _text} = repl(session, "x = MathTool.random_add(1, 0)")
      assert {false, text} = repl(session, "return x + 1")
      assert text =~ "984"
    end

    test "sessions do not share variables" do
      first = session_id(initialize())
      second = session_id(initialize())

      assert {false, _text} = repl(first, "x = 1")
      assert {false, text} = repl(second, "return x")
      assert text =~ "nil"
    end

    test "a session id nobody owns, or none at all, is 404" do
      params = %{"name" => "repl", "arguments" => %{"code" => "return 1"}}

      assert post(request("tools/call", params), [{"mcp-session-id", "gone"}]).status == 404
      assert post(request("tools/call", params)).status == 404
    end
  end

  describe "named sessions" do
    test "session/1 names the agent, whatever session id the client sends" do
      opts = opts(session: fn _conn -> [store: MemoryStore, agent_id: "plug:user:42"] end)

      assert {false, _text} = repl(nil, "x = 40", opts)
      assert {false, text} = repl("some-other-session", "return x + 2", opts)
      assert text =~ "42"

      conn = initialize(opts)
      assert session_id(conn) == "plug:user:42"
    end

    test "session/1 sees the request, so each caller gets their own agent" do
      opts =
        opts(
          session: fn conn ->
            [user] = get_req_header(conn, "x-user")
            [store: MemoryStore, agent_id: "plug:user:" <> user]
          end
        )

      alice = [{"x-user", "alice"}]
      bob = [{"x-user", "bob"}]
      params = %{"name" => "repl", "arguments" => %{"code" => "x = 1"}}

      post(request("tools/call", params), alice, opts)
      params = %{"name" => "repl", "arguments" => %{"code" => "return x"}}

      assert %{"result" => %{"content" => [%{"text" => text}]}} =
               body(post(request("tools/call", params), bob, opts))

      assert text =~ "nil"
      assert {:ok, _alice} = Legion.lookup("plug:user:alice")
      assert {:ok, _bob} = Legion.lookup("plug:user:bob")
    end
  end

  describe "transport" do
    test "a notification is accepted with no body" do
      session = session_id(initialize())
      message = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      conn = post(message, [{"mcp-session-id", session}])

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "GET and DELETE are not allowed" do
      for method <- [:get, :delete] do
        conn = MCP.Plug.call(conn(method, "/"), opts())

        assert conn.status == 405
        assert get_resp_header(conn, "allow") == ["POST"]
      end
    end

    test "an unreadable body is a parse error" do
      conn = post("{not json")

      assert conn.status == 400
      assert %{"id" => nil, "error" => %{"code" => -32_700}} = body(conn)
    end

    test "takes a body Plug.Parsers already decoded" do
      params = %{"protocolVersion" => "2025-06-18", "capabilities" => %{}, "clientInfo" => %{}}
      conn = MCP.Plug.call(conn(:post, "/", request("initialize", params)), opts())

      assert conn.status == 200
      assert body(conn)["result"]["protocolVersion"] == "2025-06-18"
    end

    test "serves a host over HTTP" do
      bandit =
        start_supervised!({Bandit, plug: {MCP.Plug, agent: MathAgent}, ip: :loopback, port: 0})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      url = "http://127.0.0.1:#{port}/"

      params = %{"protocolVersion" => "2025-06-18", "capabilities" => %{}, "clientInfo" => %{}}
      response = Req.post!(url, json: request("initialize", params))

      assert response.status == 200
      assert response.body["result"]["serverInfo"]["name"] == "Legion.Test.Support.MathAgent"
      [session] = response.headers["mcp-session-id"]

      params = %{"name" => "repl", "arguments" => %{"code" => "return MathTool.random_add(1, 0)"}}

      response =
        Req.post!(url,
          json: request("tools/call", params),
          headers: [{"mcp-session-id", session}]
        )

      assert %{"result" => %{"content" => [%{"text" => text}], "isError" => false}} =
               response.body

      assert text =~ "983"
    end
  end
end
