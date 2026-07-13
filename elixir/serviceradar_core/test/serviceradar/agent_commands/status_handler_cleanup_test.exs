defmodule ServiceRadar.AgentCommands.StatusHandlerCleanupTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AgentCommands.StatusHandler

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
      refute_received {:coordinate, _}
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
    assert_receive {:coordinate, ^data}
    assert_receive {:consume, ^data}
  end

  defp gated_state(test_pid, persister) do
    %{
      actor: :test_actor,
      result_persister: persister,
      persisted_result_broadcaster: fn data -> send(test_pid, {:broadcast, data}) end,
      cleanup_reconciler: fn data -> send(test_pid, {:cleanup, data}) end,
      callback_result_coordinator: fn data -> send(test_pid, {:coordinate, data}) end,
      result_consumers: [fn data -> send(test_pid, {:consume, data}) end]
    }
  end

  defp valid_result do
    %{
      command_id: "018f3f56-1111-7222-8333-123456789abc",
      command_type: "awx.fetch_job",
      agent_id: "agent-farm01",
      success: true,
      payload: %{"verb" => "awx.fetch_job", "job_id" => 42}
    }
  end
end
