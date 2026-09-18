if Code.ensure_loaded?(Plug) do
  defmodule Legion.MCP.Plug do
    @moduledoc """
    Serves a `Legion.Agent` as an MCP server over Streamable HTTP.

        defmodule MyApp.Assistant do
          @moduledoc "Sales assistant for The Mansion catalogue."
          use Legion.Agent

          def tools, do: [MyApp.CatalogTool]
        end

        # router
        forward "/mcp", Legion.MCP.Plug, agent: MyApp.Assistant, name: "mansion", version: "1.0.0"

    Requires the optional `:plug` dependency and `Legion` in the supervision
    tree. See `Legion.MCP` for what the server speaks and how a session
    relates to an agent.

    ## Options

      - `:agent` - the `Legion.Agent` module to expose (required)
      - `:name`, `:version` - MCP `serverInfo`, shown by hosts. Default to the
        agent module's name and `"0.0.0"`
      - `:session` - a function from the `Plug.Conn` of every request to the
        options `Legion.start_link/2` takes for that request's agent. Defaults
        to `fn _conn -> [] end`, which gives each MCP session an anonymous agent
        of its own; see "Sessions" below

    ## Sessions

    Mount the plug behind your own authentication, then tell Legion which
    agent a request belongs to:

        pipeline :mcp do
          plug MyApp.Auth.Bearer
        end

        scope "/mcp" do
          pipe_through :mcp
          forward "/", Legion.MCP.Plug, agent: MyApp.Assistant, session: &MyApp.MCP.session/1
        end

        defmodule MyApp.MCP do
          def session(conn) do
            user = conn.assigns.current_user

            [
              agent_id: "mcp:user:\#{user.id}",
              idle_timeout: :timer.minutes(30),
              vault: [current_user: user],
              rate_limit: [
                rules: [
                  %Legion.RateLimiter.Rule{
                    identity: %{"user" => user.id},
                    policy: %Legion.RateLimiter.Policy{window_ms: :timer.minutes(1), max_evals: 30}
                  }
                ]
              ]
            ]
          end
        end

    With an `:agent_id` the request runs in that agent, started on demand and
    found again on every later request whatever session id the client sends,
    so a user who comes back tomorrow, or from another host, continues the
    same conversation. `:agent_id` needs a store; see `Legion.Store`. `:vault`
    is how tools learn who is calling.

    Without an `:agent_id`, `initialize` starts a new anonymous agent and the
    agent's id becomes the `Mcp-Session-Id` the client sends back. A request
    whose session id names no live agent is answered with 404, and the client
    initializes again. Anonymous agents are not persisted, and without an
    `:idle_timeout` they live until the node stops.

    A stable id belongs to whoever your authentication lets through, never to
    whoever holds a session id; mount the plug behind authentication when ids
    are stable. Anonymous sessions carry no data of anyone else's, and a
    session id is 128 random bits, but nothing here limits how many an
    unauthenticated client may open: rate limit `initialize` in a plug of your
    own if that matters.

    ## Transport

    The server answers every request with a JSON body, sends nothing on its
    own and does not stream, so `GET` and `DELETE` are answered with 405. It
    reads a body that `Plug.Parsers` already decoded, or decodes one itself.
    """

    @behaviour Plug

    import Plug.Conn

    alias Legion.MCP

    @impl Plug
    def init(opts) do
      agent = Keyword.fetch!(opts, :agent)

      %{
        agent: agent,
        name: Keyword.get(opts, :name, inspect(agent)),
        version: Keyword.get(opts, :version, "0.0.0"),
        session: Keyword.get(opts, :session, fn _conn -> [] end)
      }
    end

    @impl Plug
    def call(%Plug.Conn{method: "POST"} = conn, opts) do
      with {:ok, message, conn} <- read_message(conn),
           {:ok, agent} <- agent(conn, message, opts) do
        conn = put_resp_header(conn, "mcp-session-id", Legion.get_agent_id(agent))

        case MCP.handle(message, agent, opts) do
          nil -> send_resp(conn, 202, "")
          response -> json(conn, 200, response)
        end
      else
        {:error, :parse, conn} ->
          error = %{"code" => -32_700, "message" => "Parse error"}
          json(conn, 400, %{"jsonrpc" => "2.0", "id" => nil, "error" => error})

        {:error, :session} ->
          send_resp(conn, 404, "")
      end
    end

    def call(conn, _opts) do
      conn |> put_resp_header("allow", "POST") |> send_resp(405, "")
    end

    defp read_message(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
      with {:ok, body, conn} <- read_body(conn),
           {:ok, message} <- Jason.decode(body) do
        {:ok, message, conn}
      else
        _ -> {:error, :parse, conn}
      end
    end

    defp read_message(conn), do: {:ok, conn.body_params, conn}

    # A request with an agent id of its own, or an initialize, starts or finds
    # that agent. Anything else must name a live agent by its session id.
    defp agent(conn, message, opts) do
      session = opts.session.(conn)

      if session[:agent_id] || message["method"] == "initialize" do
        {:ok, MCP.agent(opts.agent, session)}
      else
        lookup(get_req_header(conn, "mcp-session-id"))
      end
    end

    defp lookup([session_id]) do
      with true <- String.valid?(session_id),
           {:ok, agent} <- Legion.lookup(session_id) do
        {:ok, agent}
      else
        _ -> {:error, :session}
      end
    end

    defp lookup(_headers), do: {:error, :session}

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end
end
