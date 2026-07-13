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
end
