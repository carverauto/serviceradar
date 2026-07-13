defmodule ServiceRadar.AgentCommands.StatusHandlerResultGateDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.StatusHandler
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @actor SystemActor.system(:agent_command_status_result_gate_db_test)

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "only an exact persisted terminal result reaches any downstream consumer" do
    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "test.exact_result",
          agent_id: "agent-farm01",
          partition_id: "default",
          payload: %{"request" => "bounded"},
          context: %{"scope" => "test"},
          ttl_seconds: 60
        },
        actor: @actor
      )

    state = state(self())

    exact = %{
      command_id: command.id,
      command_type: command.command_type,
      agent_id: command.agent_id,
      success: true,
      message: "first terminal message",
      payload: %{"ok" => true, "value" => 7}
    }

    assert {:noreply, ^state} = StatusHandler.handle_info({:command_result, exact}, state)
    assert_all_consumers(exact)

    assert {:ok, completed} = AgentCommand.get_by_id(command.id, actor: @actor)
    assert completed.status == :completed
    assert completed.message == "first terminal message"
    assert completed.result_payload == exact.payload

    replay = %{exact | message: "must not replace terminal message"}
    assert {:noreply, ^state} = StatusHandler.handle_info({:command_result, replay}, state)
    assert_all_consumers(replay)

    assert {:ok, replayed} = AgentCommand.get_by_id(command.id, actor: @actor)
    assert replayed.message == "first terminal message"

    mismatches = [
      %{exact | agent_id: "agent-tonka01"},
      %{exact | command_type: "test.wrong_type"},
      %{exact | command_id: Ash.UUID.generate()},
      %{exact | payload: %{"ok" => true, "value" => 8}}
    ]

    Enum.each(mismatches, fn mismatch ->
      assert {:noreply, ^state} = StatusHandler.handle_info({:command_result, mismatch}, state)
      refute_receive {:broadcast, _}, 25
      refute_receive {:cleanup, _}, 25
      refute_receive {:callback_coordinate, _}, 25
      refute_receive {:secure_coordinate, _}, 25
      refute_receive {:consume, _}, 25
    end)

    assert {:ok, unchanged} = AgentCommand.get_by_id(command.id, actor: @actor)
    assert unchanged.message == "first terminal message"
    assert unchanged.result_payload == exact.payload
  end

  defp state(test_pid) do
    %{
      actor: @actor,
      persisted_result_broadcaster: fn data -> send(test_pid, {:broadcast, data}) end,
      cleanup_reconciler: fn data -> send(test_pid, {:cleanup, data}) end,
      callback_result_coordinator: fn data -> send(test_pid, {:callback_coordinate, data}) end,
      secure_execution_result_coordinator: fn data ->
        send(test_pid, {:secure_coordinate, data})
      end,
      result_consumers: [fn data -> send(test_pid, {:consume, data}) end]
    }
  end

  defp assert_all_consumers(data) do
    assert_receive {:broadcast, ^data}
    assert_receive {:cleanup, ^data}
    assert_receive {:callback_coordinate, ^data}
    assert_receive {:secure_coordinate, ^data}
    assert_receive {:consume, ^data}
  end
end
