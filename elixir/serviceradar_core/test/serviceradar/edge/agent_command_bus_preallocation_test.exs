defmodule ServiceRadar.Edge.AgentCommandBusPreallocationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentCommandBus

  @command_id "01980a6d-4a62-7b3f-a249-5f825874ca41"
  @reference "srle1_" <> Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)

  test "explicit AWX command IDs require a typed durable-attempt context" do
    assert {:error, :preallocated_callback_attempt_context_required} =
             AgentCommandBus.dispatch("agent-farm01", "awx.launch_job", %{},
               command_id: @command_id
             )
  end

  test "secure execution attempts accept only the execution schema and never callback context" do
    opts = [
      command_id: @command_id,
      secure_execution_attempt: true,
      source: :automation
    ]

    assert {:error, :sensitive_transmit_payload_denied} =
             AgentCommandBus.dispatch(
               "agent-farm01",
               "awx.fetch_job",
               %{"api_token" => "not-stored"},
               Keyword.put(opts, :context, secure_context("awx.fetch_job", "fetch_job"))
             )

    assert {:error, :preallocated_secure_execution_attempt_context_required} =
             AgentCommandBus.dispatch(
               "agent-farm01",
               "awx.fetch_job",
               %{},
               Keyword.put(opts, :context, callback_context("awx.fetch_job"))
             )

    assert {:error, :preallocated_callback_attempt_context_required} =
             AgentCommandBus.dispatch(
               "agent-farm01",
               "awx.fetch_job",
               %{},
               command_id: @command_id,
               callback_command_attempt: true,
               source: :automation,
               context: secure_context("awx.fetch_job", "fetch_job")
             )
  end

  test "secure execution attempts reject callback grant correlation" do
    context =
      "awx.fetch_job"
      |> secure_context("fetch_job")
      |> Map.put("callback_grant_id", Ash.UUID.generate())

    assert {:error, :preallocated_secure_execution_attempt_context_required} =
             AgentCommandBus.dispatch(
               "agent-farm01",
               "awx.fetch_job",
               %{},
               command_id: @command_id,
               secure_execution_attempt: true,
               source: :automation,
               context: context
             )
  end

  test "ordinary AWX verbs retain their generated command-ID path" do
    for verb <- [
          "awx.launch_job",
          "awx.fetch_job",
          "awx.cancel_job",
          "awx.delete_callback_credential"
        ] do
      assert {:error, :sensitive_transmit_payload_denied} =
               AgentCommandBus.dispatch("agent-farm01", verb, %{"api_token" => "not-stored"})
    end
  end

  test "a typed attempt with exact schema, verb, source, and UUID passes the preallocation gate" do
    assert {:error, :sensitive_transmit_payload_denied} =
             AgentCommandBus.dispatch(
               "agent-farm01",
               "awx.launch_job",
               %{"api_token" => "not-stored"},
               command_id: @command_id,
               callback_command_attempt: true,
               source: :automation,
               context: callback_context("awx.launch_job")
             )
  end

  test "callback credential commands require a preallocated UUID" do
    assert {:error, :preallocated_command_id_required} =
             AgentCommandBus.dispatch(
               "agent-farm01",
               "awx.create_callback_credential",
               %{"launch_envelope_ref" => @reference}
             )

    assert {:error, :invalid_command_id} =
             AgentCommandBus.dispatch(
               "agent-farm01",
               "awx.create_callback_credential",
               %{"launch_envelope_ref" => @reference},
               command_id: "not-a-uuid"
             )
  end

  test "preallocated callback commands persist only the opaque envelope reference" do
    assert {:error, :invalid_launch_envelope_payload} =
             AgentCommandBus.dispatch(
               "agent-farm01",
               "awx.create_callback_credential",
               %{
                 "launch_envelope_ref" => @reference,
                 "callback_grant" => "must-not-be-persisted"
               },
               command_id: @command_id
             )

    assert {:error, :callback_credential_payload_override_forbidden} =
             AgentCommandBus.dispatch(
               "agent-farm01",
               "awx.create_callback_credential",
               %{"launch_envelope_ref" => @reference},
               command_id: @command_id,
               callback_command_attempt: true,
               source: :automation,
               context: callback_context("awx.create_callback_credential"),
               transmit_payload: %{
                 "launch_envelope_ref" => @reference,
                 "callback_grant" => "must-not-be-transmitted"
               }
             )
  end

  test "plugin action IDs are preallocatable only for a typed notification attempt" do
    payload = %{
      "schema" => "serviceradar.notification_delivery.v1",
      "delivery_id" => @command_id
    }

    assert {:error, :preallocated_notification_attempt_context_required} =
             AgentCommandBus.dispatch("agent-farm01", "plugin.run_action", payload,
               command_id: @command_id
             )

    assert {:error, :sensitive_transmit_payload_denied} =
             AgentCommandBus.dispatch(
               "agent-farm01",
               "plugin.run_action",
               Map.put(payload, "api_token", "not-stored"),
               command_id: @command_id,
               notification_delivery_attempt: true,
               source: :automation,
               context: %{"notification_delivery_id" => @command_id}
             )

    assert {:error, :preallocated_notification_attempt_context_required} =
             AgentCommandBus.dispatch("agent-farm01", "plugin.run_action", payload,
               command_id: @command_id,
               notification_delivery_attempt: true,
               source: :automation,
               context: %{"notification_delivery_id" => Ash.UUID.generate()}
             )
  end

  defp callback_context(verb) do
    %{
      "schema" => "serviceradar.automation_callback_command/v1",
      "verb" => verb
    }
  end

  defp secure_context(verb, stage) do
    %{
      "schema" => "serviceradar.automation_execution_command/v1",
      "verb" => verb,
      "stage" => stage
    }
  end
end
