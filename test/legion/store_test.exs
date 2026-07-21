defmodule Legion.StoreTest do
  use ExUnit.Case, async: true

  defmodule DefaultStore do
    @behaviour Legion.Store

    @impl Legion.Store
    def get(_agent_id), do: :error

    @impl Legion.Store
    def list(_limit), do: []

    @impl Legion.Store
    def save(_payload), do: :ok
  end

  defmodule StepStore do
    @behaviour Legion.Store

    @impl Legion.Store
    def persistence_frequency, do: :step

    @impl Legion.Store
    def get(_agent_id), do: :error

    @impl Legion.Store
    def list(_limit), do: []

    @impl Legion.Store
    def save(_payload), do: :ok
  end

  defmodule InvalidStore do
    @behaviour Legion.Store

    @impl Legion.Store
    def persistence_frequency, do: :often

    @impl Legion.Store
    def get(_agent_id), do: :error

    @impl Legion.Store
    def list(_limit), do: []

    @impl Legion.Store
    def save(_payload), do: :ok
  end

  test "defaults stores without a frequency callback to :turn" do
    assert Legion.Store.persistence_frequency(DefaultStore) == :turn
    assert Legion.Store.persistence_frequency(nil) == :turn
  end

  test "returns a store's declared :step frequency" do
    assert Legion.Store.persistence_frequency(StepStore) == :step
  end

  test "rejects unsupported frequencies" do
    assert_raise ArgumentError, ~r/must return :turn or :step, got: :often/, fn ->
      Legion.Store.persistence_frequency(InvalidStore)
    end
  end
end
