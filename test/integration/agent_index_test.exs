defmodule Legion.Integration.AgentIndexTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  test "resolves ownership and process exit across connected nodes" do
    started_distribution? = start_distribution()
    peer_name = String.to_atom("legion_peer_#{System.unique_integer([:positive])}")
    {:ok, peer, peer_node} = :peer.start_link(%{name: peer_name})

    try do
      :ok = :global.sync()
      :ok = :rpc.call(peer_node, :global, :sync, [])

      {Legion.AgentIndex, binary, filename} = :code.get_object_code(Legion.AgentIndex)

      assert {:module, Legion.AgentIndex} =
               :rpc.call(
                 peer_node,
                 :code,
                 :load_binary,
                 [Legion.AgentIndex, filename, binary]
               )

      agent_id = "remote-owner"
      remote_pid = :rpc.call(peer_node, :erlang, :spawn, [:timer, :sleep, [:infinity]])

      assert :yes =
               :rpc.call(peer_node, Legion.AgentIndex, :register_name, [agent_id, remote_pid])

      assert {:ok, ^remote_pid} = Legion.lookup(agent_id)

      assert {:error, {:already_started, ^remote_pid}} =
               Agent.start_link(fn -> %{} end, name: Legion.AgentIndex.name(agent_id))

      monitor_ref = Process.monitor(remote_pid)
      Process.exit(remote_pid, :kill)

      assert_receive {:DOWN, ^monitor_ref, :process, ^remote_pid, :killed}
      assert_eventually(fn -> Legion.lookup(agent_id) == :error end)
    after
      :peer.stop(peer)
      if started_distribution?, do: Node.stop()
    end
  end

  defp start_distribution do
    if Node.alive?() do
      false
    else
      {_output, 0} = System.cmd("epmd", ["-daemon"])
      origin_name = String.to_atom("legion_origin_#{System.unique_integer([:positive])}")
      {:ok, _pid} = Node.start(origin_name, :shortnames)
      true
    end
  end

  defp assert_eventually(condition, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for(condition, deadline)
  end

  defp wait_for(condition, deadline) do
    cond do
      condition.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition was not met within the timeout")

      true ->
        Process.sleep(10)
        wait_for(condition, deadline)
    end
  end
end
