defmodule Legion.Recovery do
  @moduledoc false

  alias Legion.Store.Payload

  def start_link(:error), do: :ignore

  def start_link({:ok, config}) do
    Task.start_link(fn -> run(config) end)
  end

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

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      restart: :temporary
    }
  end
end
