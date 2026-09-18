if Code.ensure_loaded?(Anubis.Server.Component) do
  defmodule Legion.MCP.Repl do
    @moduledoc """
    Execute code in this server's sandbox. The language, its rules and the tool modules you
    can call are described in the server instructions. Variables persist across calls
    within this session unless the instructions say otherwise.
    """

    use Anubis.Server.Component, type: :tool

    alias Anubis.Server.Frame
    alias Anubis.Server.Response
    alias Legion.MCP.Server

    schema do
      field :code, :string, required: true, description: "Code to execute in the sandbox"
    end

    # The agent owns the variables, saves every step and enforces the rate
    # limit; this is one `Legion.eval/3` call dressed as a tool result.
    @impl true
    def execute(%{code: code}, %Frame{assigns: %{legion_server: _server}} = frame) do
      {agent, frame} = Server.resolve_agent(frame)

      reply =
        case Legion.eval(agent, code) do
          {:ok, text} ->
            Response.text(Response.tool(), text)

          {:error, error} ->
            Response.error(Response.tool(), error)

          {:cancel, {:rate_limited, violations}} ->
            limits = Enum.join(violations, ", ")
            Response.error(Response.tool(), "Rate limit exceeded (#{limits}). Try again later.")
        end

      {:reply, reply, frame}
    end

    def execute(_params, %Frame{} = frame) do
      message = "Session is not initialized: send notifications/initialized before calling tools."
      {:reply, Response.error(Response.tool(), message), frame}
    end
  end
end
