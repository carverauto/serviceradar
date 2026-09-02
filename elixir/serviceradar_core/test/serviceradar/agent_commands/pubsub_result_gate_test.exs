defmodule ServiceRadar.AgentCommands.PubSubResultGateTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentCommands.PubSub

  setup do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if is_nil(Process.whereis(ServiceRadar.PubSub)) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    :ok
  end

  test "raw results reach only ingress and exact persisted results reach downstream topics" do
    command_id = Ash.UUID.generate()
    ingress = subscriber(self(), :ingress, &PubSub.subscribe_ingress/0)
    downstream = subscriber(self(), :downstream, &PubSub.subscribe/0)
    scoped = subscriber(self(), :scoped, fn -> PubSub.subscribe(command_id) end)

    for tag <- [:ingress, :downstream, :scoped], do: assert_receive({:ready, ^tag})

    data = %{
      command_id: command_id,
      command_type: "awx.fetch_job",
      agent_id: "agent-farm01",
      success: true,
      payload: %{"ok" => true}
    }

    PubSub.broadcast_result(data)

    assert_receive {:ingress, {:command_result, %{command_id: ^command_id}}}
    refute_receive {:downstream, {:command_result, _}}, 50
    refute_receive {:scoped, {:command_result, _}}, 50

    PubSub.broadcast_persisted_result(data)

    assert_receive {:downstream, {:command_result, %{command_id: ^command_id}}}
    assert_receive {:scoped, {:command_result, %{command_id: ^command_id}}}
    refute_receive {:ingress, {:command_result, _}}, 50

    Enum.each([ingress, downstream, scoped], &send(&1, :stop))
  end

  test "raw ack and progress stay on ingress while persisted updates reach only public subscribers" do
    ingress = subscriber(self(), :ingress, &PubSub.subscribe_ingress/0)
    downstream = subscriber(self(), :downstream, &PubSub.subscribe/0)

    for tag <- [:ingress, :downstream], do: assert_receive({:ready, ^tag})

    ack = command_update("ack-command")
    progress = Map.put(command_update("progress-command"), :progress_percent, 41)

    PubSub.broadcast_ack(ack)
    assert_receive {:ingress, {:command_ack, %{command_id: "ack-command"}}}
    refute_receive {:downstream, {:command_ack, _}}, 50

    PubSub.broadcast_persisted_ack(ack)
    assert_receive {:downstream, {:command_ack, %{command_id: "ack-command"}}}
    refute_receive {:ingress, {:command_ack, _}}, 50

    PubSub.broadcast_progress(progress)
    assert_receive {:ingress, {:command_progress, %{command_id: "progress-command"}}}
    refute_receive {:downstream, {:command_progress, _}}, 50

    PubSub.broadcast_persisted_progress(progress)
    assert_receive {:downstream, {:command_progress, %{command_id: "progress-command"}}}
    refute_receive {:ingress, {:command_progress, _}}, 50

    Enum.each([ingress, downstream], &send(&1, :stop))
  end

  test "sweep dispatch envelopes reach public subscribers without entering persistence ingress" do
    ingress = subscriber(self(), :ingress, &PubSub.subscribe_ingress/0)
    downstream = subscriber(self(), :downstream, &PubSub.subscribe/0)

    for tag <- [:ingress, :downstream], do: assert_receive({:ready, ^tag})

    event = %{
      sweep_group_id: "group-1",
      commands: [%{agent_id: "agent-a", command_id: "command-a"}],
      failures: [%{agent_id: "agent-b", reason: {:agent_offline, "agent-b"}}]
    }

    PubSub.broadcast_sweep_dispatch(event)

    assert_receive {:downstream, {:sweep_dispatch, ^event}}
    refute_receive {:ingress, {:sweep_dispatch, _}}, 50

    Enum.each([ingress, downstream], &send(&1, :stop))
  end

  defp subscriber(parent, tag, subscribe) do
    spawn_link(fn ->
      :ok = subscribe.()
      send(parent, {:ready, tag})
      relay(parent, tag)
    end)
  end

  defp command_update(command_id) do
    %{
      command_id: command_id,
      command_type: "sweep.run_group",
      agent_id: "agent-a",
      partition_id: "farm01",
      message: "accepted"
    }
  end

  defp relay(parent, tag) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, {tag, message})
        relay(parent, tag)
    end
  end
end
