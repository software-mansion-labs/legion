defmodule Legion.StoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Legion.Store.Conversation.{Metadata, State}

  defmodule DefaultStore do
    use Legion.Store

    def get(_agent_id), do: :error
  end

  defmodule CustomStore do
    use Legion.Store

    def get(_agent_id), do: :error
    def save(_agent_id, _payload), do: :custom
  end

  test "default save/2 warns and returns :ok for conversation state" do
    payload = %State{messages: [], bindings: []}

    log =
      capture_log(fn ->
        assert :ok = DefaultStore.save("agent-1", payload)
      end)

    assert log =~ "Store #{inspect(DefaultStore)} does not persist conversation state"
  end

  test "default save/2 warns and returns :ok for conversation metadata" do
    payload = %Metadata{agent_module: SomeAgent, parent_agent_id: nil, started_at: 1}

    log =
      capture_log(fn ->
        assert :ok = DefaultStore.save("agent-1", payload)
      end)

    assert log =~ "Store #{inspect(DefaultStore)} does not persist conversation metadata"
  end

  test "default save/2 warns and returns :ok for conversation status" do
    log =
      capture_log(fn ->
        assert :ok = DefaultStore.save("agent-1", {:status, :running})
      end)

    assert log =~ "Store #{inspect(DefaultStore)} does not persist conversation status"
  end

  test "default save/2 can be overridden" do
    assert :custom = CustomStore.save("agent-1", %State{messages: [], bindings: []})
  end
end
