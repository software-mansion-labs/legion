defmodule Legion.MCP.PostgresDbTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Legion.MCP
  alias Legion.RateLimiter.{Policy, Rule}
  alias Legion.Store.Payload
  alias Legion.Test.Support.MathAgent
  alias Legion.Test.Support.PostgresRepo, as: Repo

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  defmodule RateLimiter do
    use Legion.RateLimiter.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  setup do
    Repo.query!("TRUNCATE legion_agents", [])
    start_supervised!({DynamicSupervisor, name: Legion.AgentSupervisor, strategy: :one_for_one})
    :ok
  end

  # Two evaluations a minute per user, each user in an agent of their own.
  defp session(conn) do
    [user] = get_req_header(conn, "x-user")
    policy = %Policy{window_ms: 60_000, max_evals: 2}

    [
      store: Store,
      agent_id: "mcp:user:" <> user,
      rate_limit: [
        limiter: RateLimiter,
        rules: [%Rule{identity: %{"user" => user}, policy: policy}]
      ]
    ]
  end

  defp repl(user, code) do
    opts = MCP.Plug.init(agent: MathAgent, session: &session/1)
    params = %{"name" => "repl", "arguments" => %{"code" => code}}
    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => params}

    conn =
      conn(:post, "/", Jason.encode!(message))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-user", user)
      |> MCP.Plug.call(opts)

    %{"result" => %{"content" => [%{"text" => text}], "isError" => error?}} =
      Jason.decode!(conn.resp_body)

    {error?, text}
  end

  test "a user's calls land in the store and count towards their max_evals" do
    assert {false, first} = repl("alice", "return 1 + 1")
    assert {false, _second} = repl("alice", "return 2 + 2")
    assert {true, "Rate limit exceeded (max_evals)." <> _} = repl("alice", "return 3 + 3")
    assert {false, _bob} = repl("bob", "return 1")

    assert {:ok,
            %Payload{
              agent_module: MathAgent,
              status: :idle,
              ratelimit_metadata: %{"user" => "alice"},
              usage: [%{"evals" => 1}, %{"evals" => 1}],
              conversation_state: %{
                messages: [
                  %{type: :assistant},
                  %{type: :eval_result} = saved,
                  %{type: :assistant},
                  %{type: :eval_result}
                ]
              }
            }} = Store.get("mcp:user:alice")

    assert saved.content == first
  end
end
