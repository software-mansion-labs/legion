defmodule Legion.Recovery do
  @moduledoc """
  Startup worker for persisted interrupted root runs.

  `Legion.Application` starts this worker only when `:recovery` is configured:

      config :legion, :recovery,
        stores: [MyApp.AgentStore],
        limit: 10

  The worker calls `list(limit)` on every configured store, selects payloads
  with `status: :running` and no `parent_agent_id`, then invokes
  `Legion.recover/2` for each selected run.

  Recovery deliberately does not restart sub-agents. A parent can persist its
  state before a code evaluation dispatches a sub-agent, then crash before the
  following checkpoint records that dispatch. When the parent recovers, it can
  replay that evaluation and dispatch a new sub-agent; recovering the recorded
  child independently could execute the same work twice.

  `limit` is both the maximum number of payloads read from each store and the
  maximum number of recoveries in flight across all stores. Recovery runs
  asynchronously during application startup. The worker performs the recovery
  scan, then exits and is not restarted. Configure it through the application
  environment rather than starting it directly.

  The temporary agent process drives each interrupted root run to completion,
  then stops.
  """

  alias Legion.Store.Payload

  @doc false
  def start_link(:error), do: :ignore

  def start_link({:ok, config}) do
    Task.start_link(fn -> run(config) end)
  end

  @doc false
  def run(config) do
    stores = Keyword.fetch!(config, :stores)
    limit = Keyword.fetch!(config, :limit)

    stores
    |> Enum.flat_map(fn store ->
      store.list(limit)
      |> Enum.map(fn payload -> {store, payload} end)
    end)
    |> Enum.filter(fn {_store, payload} -> running_root?(payload) end)
    |> Task.async_stream(
      fn {store, %Payload{agent_id: agent_id}} -> Legion.recover(agent_id, store: store) end,
      max_concurrency: limit,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end

  defp running_root?(%Payload{status: :running, parent_agent_id: nil}), do: true
  defp running_root?(_payload), do: false

  @doc false
  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      restart: :temporary
    }
  end
end
