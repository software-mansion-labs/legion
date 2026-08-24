defmodule Legion.Sandbox.Popcorn.Host do
  @moduledoc """
  Registry of browser "host" processes for `Legion.Sandbox.Popcorn`.

  A host is whatever process bridges an agent's evaluations to a connected
  browser - typically a Phoenix Channel in the consuming application. The
  host calls `register/1` with the agent's id; from then on the sandbox
  routes that agent's evaluations to it using the message protocol described
  in `Legion.Sandbox.Popcorn`. Registration is released automatically when
  the host process dies.

  The registry runs under Legion's supervisor.
  """

  @registry Legion.Sandbox.Popcorn.HostRegistry
  @poll_interval_ms 100

  @doc false
  def child_spec(_opts),
    do: %{id: @registry, start: {__MODULE__, :start_link, []}, type: :supervisor}

  @doc false
  # `:ignore` when the registry is already up, so embedding `{Legion, []}`
  # into a second supervision tree (as tests do) does not fail on the
  # globally named registry.
  def start_link do
    case Registry.start_link(keys: :unique, name: @registry) do
      {:error, {:already_started, _pid}} -> :ignore
      other -> other
    end
  end

  @doc "Registers the calling process as the host for `agent_id`."
  @spec register(String.t()) :: :ok | {:error, {:already_registered, pid()}}
  def register(agent_id) when is_binary(agent_id) do
    case Registry.register(@registry, agent_id, nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, pid}} when pid == self() -> :ok
      {:error, {:already_registered, _pid}} = error -> error
    end
  end

  @doc "The host currently registered for `agent_id`, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(agent_id) when is_binary(agent_id) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Blocks until a host is registered for `agent_id` and returns its pid.

  Polls every #{@poll_interval_ms}ms with no deadline of its own - callers
  run inside `Legion.Sandbox.Runner`, whose timeout bounds the wait.
  """
  @spec await(String.t()) :: pid()
  def await(agent_id) when is_binary(agent_id) do
    case whereis(agent_id) do
      nil ->
        Process.sleep(@poll_interval_ms)
        await(agent_id)

      pid ->
        pid
    end
  end
end
