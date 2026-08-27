defmodule ServiceRadar.AgentCommands.StatusHandlerResultGateDbTest do
  use ServiceRadar.DataCase, async: true

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
      partition_id: command.partition_id,
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
    refute_receive {:broadcast, _}, 25
    refute_receive {:cleanup, _}, 25
    refute_receive {:callback_coordinate, _}, 25
    refute_receive {:secure_coordinate, _}, 25
    refute_receive {:consume, _}, 25

    assert {:ok, replayed} = AgentCommand.get_by_id(command.id, actor: @actor)
    assert replayed.message == "first terminal message"

    # An exact replay remains eligible for crash-window recovery; every field
    # visible to downstream consumers must match the durable row.
    assert {:noreply, ^state} = StatusHandler.handle_info({:command_result, exact}, state)
    assert_all_consumers(exact)

    mismatches = [
      %{exact | agent_id: "agent-tonka01"},
      %{exact | partition_id: "tonka01"},
      Map.delete(exact, :partition_id),
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

  test "protected AWX failures cannot persist or broadcast raw plugin evidence" do
    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "awx.fetch_job",
          agent_id: "agent-farm01",
          partition_id: "default",
          payload: %{"request" => "bounded"},
          context: %{"scope" => "test"},
          ttl_seconds: 60
        },
        actor: @actor
      )

    state = state(self())
    secret = "Bearer db-result-must-not-survive"

    unsafe = %{
      command_id: command.id,
      command_type: command.command_type,
      agent_id: command.agent_id,
      partition_id: command.partition_id,
      success: false,
      message: secret,
      failure_reason: {:http_error, secret},
      payload: %{"details" => secret, "raw_result_base64" => Base.encode64(secret)}
    }

    assert {:noreply, ^state} = StatusHandler.handle_info({:command_result, unsafe}, state)

    assert_receive {:broadcast, safe}
    assert safe.message == "automation command failed"
    assert safe.failure_reason == "automation_command_failed"
    assert safe.payload == %{"verb" => "awx.fetch_job", "ok" => false}
    refute inspect(safe) =~ secret

    assert_receive {:cleanup, ^safe}
    assert_receive {:callback_coordinate, ^safe}
    assert_receive {:secure_coordinate, ^safe}
    assert_receive {:consume, ^safe}

    assert {:ok, completed} = AgentCommand.get_by_id(command.id, actor: @actor)
    assert completed.status == :failed
    assert completed.message == "automation command failed"
    assert completed.failure_reason == "automation_command_failed"
    assert completed.result_payload == %{"verb" => "awx.fetch_job", "ok" => false}
    refute inspect(completed) =~ secret
  end

  test "ack and progress require exact authenticated command provenance" do
    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "awx.fetch_job",
          agent_id: "agent-farm01",
          partition_id: "default",
          payload: %{"request" => "bounded"},
          context: %{"scope" => "test"},
          ttl_seconds: 60
        },
        actor: @actor
      )

    state = state(self())
    secret = "Bearer downgraded-progress-must-not-survive"

    mismatched = %{
      command_id: command.id,
      command_type: "mtr.run",
      agent_id: command.agent_id,
      partition_id: command.partition_id,
      message: secret,
      progress_percent: 25,
      payload: %{"details" => secret}
    }

    assert {:noreply, ^state} = StatusHandler.handle_info({:command_ack, mismatched}, state)
    assert {:noreply, ^state} = StatusHandler.handle_info({:command_progress, mismatched}, state)

    assert {:ok, untouched} = AgentCommand.get_by_id(command.id, actor: @actor)
    assert untouched.status == :queued
    assert is_nil(untouched.message)
    assert is_nil(untouched.progress_payload)

    protected = %{mismatched | command_type: command.command_type}
    assert {:noreply, ^state} = StatusHandler.handle_info({:command_ack, protected}, state)
    assert {:noreply, ^state} = StatusHandler.handle_info({:command_progress, protected}, state)

    assert {:ok, running} = AgentCommand.get_by_id(command.id, actor: @actor)
    assert running.status == :running
    assert running.message == "automation command in progress"
    assert running.progress_payload == %{}
    refute inspect(running) =~ secret

    for wrong_partition <- ["tonka01", nil] do
      rejected =
        if wrong_partition,
          do: %{protected | partition_id: wrong_partition},
          else: Map.delete(protected, :partition_id)

      assert {:noreply, ^state} = StatusHandler.handle_info({:command_ack, rejected}, state)
      assert {:noreply, ^state} = StatusHandler.handle_info({:command_progress, rejected}, state)
    end
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
      result_coordination_dispatcher: fn work ->
        work.()
        :ok
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
