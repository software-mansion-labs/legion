defmodule Legion.AgentIndex do
  @moduledoc """
  Cluster-wide process index used by Legion's agent servers.

  Implements the `:via` registration callbacks over `:global`. Starting an
  agent atomically claims its agent ID across connected nodes. The name is
  released automatically when the process stops.
  """

  @doc false
  def name(agent_id) do
    {:via, __MODULE__, agent_id}
  end

  @doc false
  def register_name(agent_id, pid) do
    :global.register_name(key(agent_id), pid)
  end

  @doc false
  def unregister_name(agent_id) do
    :global.unregister_name(key(agent_id))
  end

  @doc false
  def whereis_name(agent_id) do
    :global.whereis_name(key(agent_id))
  end

  @doc false
  def send(agent_id, message) do
    :global.send(key(agent_id), message)
  end

  @doc false
  def lookup(agent_id) do
    case whereis_name(agent_id) do
      :undefined -> :error
      pid -> {:ok, pid}
    end
  end

  defp key(agent_id), do: {:legion_agent, agent_id}
end
