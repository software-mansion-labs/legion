defmodule Legion.Sandbox.Popcorn.HostTest do
  use ExUnit.Case, async: true

  alias Legion.Sandbox.Popcorn.Host

  defp unique_agent_id, do: "host-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(6))

  test "register/whereis round trip" do
    agent_id = unique_agent_id()
    assert Host.whereis(agent_id) == nil
    assert :ok = Host.register(agent_id)
    assert Host.whereis(agent_id) == self()
  end

  test "second registration for the same agent is rejected" do
    agent_id = unique_agent_id()
    :ok = Host.register(agent_id)

    task = Task.async(fn -> Host.register(agent_id) end)
    assert {:error, {:already_registered, pid}} = Task.await(task)
    assert pid == self()
  end

  test "registration is released when the host dies" do
    agent_id = unique_agent_id()

    {pid, ref} =
      spawn_monitor(fn ->
        :ok = Host.register(agent_id)

        receive do
          :stop -> :ok
        end
      end)

    await_registered(agent_id, pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    await_unregistered(agent_id)
  end

  test "await/1 blocks until a host registers" do
    agent_id = unique_agent_id()
    parent = self()

    waiter = spawn_link(fn -> send(parent, {:found, Host.await(agent_id)}) end)
    refute_receive {:found, _pid}, 150

    :ok = Host.register(agent_id)
    assert_receive {:found, pid}, 1_000
    assert pid == self()
    _ = waiter
  end

  defp await_registered(agent_id, pid) do
    case Host.whereis(agent_id) do
      ^pid -> :ok
      _ -> Process.sleep(10) && await_registered(agent_id, pid)
    end
  end

  defp await_unregistered(agent_id) do
    case Host.whereis(agent_id) do
      nil -> :ok
      _ -> Process.sleep(10) && await_unregistered(agent_id)
    end
  end
end
