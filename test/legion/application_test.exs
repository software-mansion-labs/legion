defmodule Legion.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.fetch_env(:legion, :recovery)

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:legion, :recovery, config)
        :error -> Application.delete_env(:legion, :recovery)
      end
    end)
  end

  test "passes absent recovery configuration to the recovery child" do
    Application.delete_env(:legion, :recovery)

    assert {Legion.Recovery, :error} in Legion.Application.children()
  end

  test "passes configured recovery options to the recovery child" do
    config = [stores: [RecoveryStore], limit: 3]
    Application.put_env(:legion, :recovery, config)

    assert Enum.member?(Legion.Application.children(), {Legion.Recovery, {:ok, config}})
  end
end
