defmodule ServiceRadar.AgentCommands.StatusHandlerPublicForwardTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.AgentCommands.StatusHandler

  @moduletag :db_free

  setup do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    :ok = PubSub.subscribe()
    :ok
  end

  test "persisted ack progress and result publish once without looping into ingress" do
    test_pid = self()

    start_supervised!(
      {StatusHandler,
       ack_persister: persister(test_pid, :ack),
       progress_persister: persister(test_pid, :progress),
       result_persister: persister(test_pid, :result),
       persisted_ack_broadcaster: &PubSub.broadcast_persisted_ack/1,
       persisted_progress_broadcaster: &PubSub.broadcast_persisted_progress/1,
       persisted_result_broadcaster: &PubSub.broadcast_persisted_result/1,
       ack_consumer: fn _data -> :ok end,
       progress_consumers: [],
       cleanup_reconciler: fn _data -> :ok end,
       callback_result_coordinator: fn _data -> :ok end,
       secure_execution_result_coordinator: fn _data -> :ok end,
       result_coordination_dispatcher: fn work ->
         work.()
         :ok
       end,
       result_consumers: []}
    )

    _ = :sys.get_state(StatusHandler)

    ack = command_update("ack-command")
    progress = Map.put(command_update("progress-command"), :progress_percent, 72)
    result = Map.merge(command_update("result-command"), %{success: true, payload: %{}})

    PubSub.broadcast_ack(ack)
    assert_receive {:persist, :ack, %{command_id: "ack-command"}}
    assert_receive {:command_ack, %{command_id: "ack-command"}}

    PubSub.broadcast_progress(progress)
    assert_receive {:persist, :progress, %{command_id: "progress-command"}}
    assert_receive {:command_progress, %{command_id: "progress-command"}}

    PubSub.broadcast_result(result)
    assert_receive {:persist, :result, %{command_id: "result-command"}}
    assert_receive {:command_result, %{command_id: "result-command"}}

    refute_receive {:persist, _kind, _duplicate}, 100
  end

  test "rejected persistence never publishes an unaudited update" do
    test_pid = self()

    reject = fn data, _actor ->
      send(test_pid, {:rejected, data.command_id})
      {:error, :provenance_rejected}
    end

    start_supervised!(
      {StatusHandler,
       ack_persister: reject,
       progress_persister: reject,
       result_persister: reject,
       persisted_ack_broadcaster: &PubSub.broadcast_persisted_ack/1,
       persisted_progress_broadcaster: &PubSub.broadcast_persisted_progress/1,
       persisted_result_broadcaster: &PubSub.broadcast_persisted_result/1,
       ack_consumer: fn _data -> :ok end,
       progress_consumers: [],
       cleanup_reconciler: fn _data -> :ok end,
       callback_result_coordinator: fn _data -> :ok end,
       secure_execution_result_coordinator: fn _data -> :ok end,
       result_coordination_dispatcher: fn _work -> :ok end,
       result_consumers: []}
    )

    _ = :sys.get_state(StatusHandler)

    PubSub.broadcast_ack(command_update("rejected-ack"))
    assert_receive {:rejected, "rejected-ack"}
    refute_receive {:command_ack, %{command_id: "rejected-ack"}}, 50

    PubSub.broadcast_progress(command_update("rejected-progress"))
    assert_receive {:rejected, "rejected-progress"}
    refute_receive {:command_progress, %{command_id: "rejected-progress"}}, 50

    PubSub.broadcast_result(
      Map.merge(command_update("rejected-result"), %{success: false, payload: %{}})
    )

    assert_receive {:rejected, "rejected-result"}
    refute_receive {:command_result, %{command_id: "rejected-result"}}, 50
  end

  defp persister(test_pid, kind) do
    fn data, _actor ->
      send(test_pid, {:persist, kind, data})
      :ok
    end
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
end
