defmodule ServiceRadar.AgentCommands.StatusHandlerCleanupTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.AgentCommands.StatusHandler

  @moduletag :requires_app

  defmodule SecretDatabaseError do
    @moduledoc false
    defexception [:message]
  end

  test "database failure logging never renders secret-bearing errors" do
    secret = "Bearer status-handler-must-not-log-this"
    reason = %SecretDatabaseError{message: secret}

    log =
      capture_log(fn ->
        assert :ok =
                 StatusHandler.log_control_query_failure(
                   "persist exact command result",
                   "018f3f56-1111-7222-8333-123456789abc",
                   reason
                 )
      end)

    assert log =~ "failed to persist exact command result"
    refute log =~ secret
    refute log =~ "Bearer"
  end

  test "cleanup results retain only bounded identifiers and status" do
    data = %{
      command_id: "018f3f56-1111-7222-8333-123456789abc",
      command_type: "awx.delete_callback_credential",
      success: true,
      message: "upstream response_body contained callback-bearer",
      failure_reason: "launch-envelope:secret",
      response_body: "top-level callback-bearer:must-not-persist",
      callback_idempotency_key: "must-not-persist",
      payload: %{
        "verb" => "awx.delete_callback_credential",
        "ok" => true,
        "credential_id" => 401,
        "credential_type_id" => 91,
        "cleanup_status" => "deleted",
        "response_body" => "callback-bearer:must-not-persist",
        "envelope_ref" => "launch-envelope:must-not-persist"
      }
    }

    safe = StatusHandler.sanitize_cleanup_result(data)

    assert safe.payload == %{
             "verb" => "awx.delete_callback_credential",
             "ok" => true,
             "credential_id" => 401,
             "credential_type_id" => 91,
             "cleanup_status" => "deleted"
           }

    assert safe.message == "cleanup command completed"
    assert safe.failure_reason == nil
    refute inspect(safe) =~ "callback-bearer"
    refute inspect(safe) =~ "launch-envelope"
    refute inspect(safe) =~ "response_body"
  end

  test "failed cancellation results discard untrusted messages and response payloads" do
    data = %{
      command_type: "awx.cancel_job",
      success: false,
      message: "Bearer must-not-persist",
      failure_reason: "response_body=must-not-persist",
      payload: %{"error" => "must-not-persist", "response_body" => "must-not-persist"}
    }

    safe = StatusHandler.sanitize_cleanup_result(data)

    assert safe.payload == %{
             "verb" => "invalid",
             "ok" => false,
             "job_id" => nil,
             "status" => nil
           }

    assert safe.message == "cleanup command failed"
    assert safe.failure_reason == "cleanup_command_failed"
    refute inspect(safe) =~ "must-not-persist"
  end

  test "no result consumer runs unless exact result persistence succeeds" do
    state = gated_state(self(), fn _data, _actor -> {:error, :command_result_not_persisted} end)

    for mismatch <- [:wrong_agent, :wrong_type, :unknown_uuid, :contradictory_terminal_replay] do
      data = Map.put(valid_result(), :mismatch, mismatch)
      assert {:noreply, ^state} = StatusHandler.handle_info({:command_result, data}, state)
      refute_received {:broadcast, _}
      refute_received {:cleanup, _}
      refute_received {:callback_coordinate, _}
      refute_received {:secure_coordinate, _}
      refute_received {:consume, _}
    end
  end

  test "all result consumers run after the exact terminal row is persisted" do
    state =
      gated_state(self(), fn data, _actor ->
        send(self(), {:persist, data})
        :ok
      end)

    data = valid_result()
    assert {:noreply, ^state} = StatusHandler.handle_info({:command_result, data}, state)
    assert_receive {:persist, ^data}
    assert_receive {:broadcast, ^data}
    assert_receive {:cleanup, ^data}
    assert_receive {:callback_coordinate, ^data}
    assert_receive {:secure_coordinate, ^data}
    assert_receive {:consume, ^data}
  end

  test "protected AWX results are sanitized before persistence and every consumer" do
    state =
      gated_state(self(), fn data, _actor ->
        send(self(), {:persist, data})
        :ok
      end)

    secret = "Bearer command-result-must-not-survive"

    data = %{
      command_id: "018f3f56-1111-7222-8333-123456789abc",
      command_type: "awx.fetch_job",
      agent_id: "agent-farm01",
      partition_id: "farm01",
      success: false,
      message: secret,
      failure_reason: {:http_error, secret},
      payload: %{"details" => secret, "raw_result_base64" => Base.encode64(secret)}
    }

    assert {:noreply, ^state} = StatusHandler.handle_info({:command_result, data}, state)

    assert_receive {:persist, safe}

    assert safe == %{
             command_id: data.command_id,
             command_type: data.command_type,
             agent_id: data.agent_id,
             partition_id: data.partition_id,
             success: false,
             message: "automation command failed",
             failure_reason: "automation_command_failed",
             payload: %{"verb" => "awx.fetch_job", "ok" => false}
           }

    assert_receive {:broadcast, ^safe}
    assert_receive {:cleanup, ^safe}
    assert_receive {:callback_coordinate, ^safe}
    assert_receive {:secure_coordinate, ^safe}
    assert_receive {:consume, ^safe}
    refute inspect(safe) =~ secret
  end

  test "nested provenance results persist while coordination waits off the ingress mailbox" do
    test_pid = self()
    task_supervisor = start_supervised!({Task.Supervisor, []})
    coordination_waiter = start_supervised!({Agent, fn -> nil end})

    result_coordination_dispatcher = fn work ->
      Task.Supervisor.start_child(task_supervisor, work, shutdown: 5_000)
    end

    result_persister = fn data, _actor ->
      send(test_pid, {:persisted, data.command_id})

      if data.command_id == "nested-command" do
        coordination_pid = Agent.get(coordination_waiter, & &1)
        send(coordination_pid, {:persisted, data.command_id})
      end

      :ok
    end

    callback_result_coordinator = fn
      %{command_id: "initial-command"} ->
        coordination_pid = self()
        Agent.update(coordination_waiter, fn _current -> coordination_pid end)
        send(StatusHandler, {:command_result, nested_result()})

        receive do
          {:persisted, "nested-command"} -> send(test_pid, :coordination_completed)
        after
          1_000 -> send(test_pid, :coordination_timed_out)
        end

      _other ->
        :ok
    end

    start_supervised!(
      {StatusHandler,
       result_persister: result_persister,
       persisted_result_broadcaster: fn _data -> :ok end,
       cleanup_reconciler: fn _data -> :ok end,
       callback_result_coordinator: callback_result_coordinator,
       secure_execution_result_coordinator: fn _data -> :ok end,
       result_coordination_dispatcher: result_coordination_dispatcher,
       result_consumers: []}
    )

    send(StatusHandler, {:command_result, initial_result()})

    assert_receive {:persisted, "initial-command"}
    assert_receive :coordination_completed, 2_000
    refute_received :coordination_timed_out

    assert eventually(fn -> Task.Supervisor.children(task_supervisor) == [] end)
  end

  defp gated_state(test_pid, persister) do
    %{
      actor: :test_actor,
      result_persister: persister,
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

  defp initial_result do
    valid_result()
    |> Map.put(:command_id, "initial-command")
    |> Map.put(:partition_id, "farm01")
  end

  defp nested_result do
    valid_result()
    |> Map.put(:command_id, "nested-command")
    |> Map.put(:partition_id, "farm01")
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp valid_result do
    %{
      command_id: "018f3f56-1111-7222-8333-123456789abc",
      command_type: "test.fetch_job",
      agent_id: "agent-farm01",
      success: true,
      payload: %{"verb" => "awx.fetch_job", "job_id" => 42}
    }
  end
end
