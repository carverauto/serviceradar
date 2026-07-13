defmodule ServiceRadar.Edge.AgentCommandBusPreallocationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentCommandBus

  @command_id "01980a6d-4a62-7b3f-a249-5f825874ca41"
  @reference "srle1_" <> Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)

  test "preallocated command IDs are exclusive to the callback credential verb" do
    assert {:error, :preallocated_command_id_not_allowed} =
             AgentCommandBus.dispatch("agent-farm01", "awx.launch_job", %{},
               command_id: @command_id
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
               transmit_payload: %{
                 "launch_envelope_ref" => @reference,
                 "callback_grant" => "must-not-be-transmitted"
               }
             )
  end
end
