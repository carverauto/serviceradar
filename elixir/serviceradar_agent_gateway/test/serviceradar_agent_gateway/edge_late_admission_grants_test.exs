defmodule ServiceRadarAgentGateway.EdgeLateAdmissionGrantsTest do
  @moduledoc """
  The gateway half of `IssueEdgeLateAdmissionGrants` (openspec add-edge-production-time-admission,
  task 2.5): a record from a late generation is verified here from its exact bytes before core is
  asked, and core judges it against the authority that was live when it was produced. Unlike a
  renewal, a late record need not name a scope the agent is bound to now: its assignment may be
  long gone, and core decides that from history.
  """

  use ExUnit.Case, async: false

  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias ServiceRadarAgentGateway.EdgeDeliveryGrants
  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordFactory, as: Factory

  # A synthetic UUIDv7 spool id.
  @spool_id <<0x0190_0000_0005::48, 7::4, 0x0AB::12, 2::2, 0xBA::62>>
  @identity %{component_id: "agent-1", component_type: :agent}
  @grant %EdgeSignedCapabilityV1{issuer_id: "serviceradar-core", signature: :binary.copy(<<2>>, 64)}

  setup do
    keys = Factory.keypair()
    test_pid = self()

    Application.put_env(:serviceradar_agent_gateway, :edge_late_admission_grant_rpc, fn agent_id, items ->
      send(test_pid, {:core_asked, agent_id, items})

      {:ok,
       Enum.map(items, fn item ->
         if item.sequence == 99,
           do: %{sequence: item.sequence, delivery_capability: nil, refusal: :not_yet},
           else: %{sequence: item.sequence, delivery_capability: @grant, refusal: nil}
       end)}
    end)

    # The agent holds no scope binding any more: its assignment has gone.
    :ok = EdgeRecordTrust.install(Factory.trust_document(keys.public, scopes: [], fences: []))

    on_exit(fn ->
      Application.delete_env(:serviceradar_agent_gateway, :edge_late_admission_grant_rpc)
      EdgeRecordTrust.clear()
    end)

    %{keys: keys}
  end

  test "asks core about a verified late record by its own coordinates, epoch and registry epoch", %{keys: keys} do
    now = System.os_time(:nanosecond)
    day = 24 * Factory.hour_nanos()
    late = Factory.record(keys.private, not_before: now - 3 * day, expires: now - 3 * day + Factory.hour_nanos())
    bytes = EdgeRecordV1.encode(late)

    assert {:ok, %Monitoring.EdgeDeliveryGrantResponse{results: [result]}} =
             EdgeDeliveryGrants.late(request([{7, bytes}]), @identity)

    assert result == %Monitoring.EdgeDeliveryGrantResult{sequence: 7, delivery_capability: @grant, refusal: ""}

    assert_received {:core_asked, "agent-1", [item]}

    assert item == %{
             sequence: 7,
             spool_id: @spool_id,
             event_id: late.event_id,
             record_sha256: :crypto.hash(:sha256, bytes),
             network_scope_id: Factory.network_scope_id(),
             producer_assignment_id: Factory.producer_assignment_id(),
             run_shard: late.producer_context.run_shard,
             authority_epoch: late.producer_context.authority_epoch,
             registry_epoch: late.output_contract.registry_epoch
           }
  end

  test "refuses, without asking core, a record the agent did not produce or that does not verify", %{keys: keys} do
    foreign = Factory.record(keys.private, principal: "agent-2")
    forged = Factory.record(Factory.keypair().private)

    assert {:ok, %Monitoring.EdgeDeliveryGrantResponse{results: results}} =
             EdgeDeliveryGrants.late(
               request([{1, EdgeRecordV1.encode(foreign)}, {2, EdgeRecordV1.encode(forged)}]),
               @identity
             )

    assert Enum.map(results, &{&1.sequence, &1.delivery_capability, &1.refusal}) == [
             {1, nil, "identity_conflict"},
             {2, nil, "production.signature"}
           ]

    refute_received {:core_asked, _, _}
  end

  test "relays core's answer that a record's production time has not arrived yet", %{keys: keys} do
    bytes = EdgeRecordV1.encode(Factory.record(keys.private))

    assert {:ok, %Monitoring.EdgeDeliveryGrantResponse{results: [result]}} =
             EdgeDeliveryGrants.late(request([{99, bytes}]), @identity)

    assert {result.delivery_capability, result.refusal} == {nil, "not_yet"}
  end

  test "a record signed by a compromise-revoked key gets no grant: it needs none to reach quarantine", %{
    keys: keys
  } do
    :ok =
      EdgeRecordTrust.install(Factory.trust_document(keys.public, status: "historically_revoked", scopes: [], fences: []))

    assert {:ok, %Monitoring.EdgeDeliveryGrantResponse{results: [result]}} =
             EdgeDeliveryGrants.late(request([{1, EdgeRecordV1.encode(Factory.record(keys.private))}]), @identity)

    assert result.refusal == "key_historically_revoked"
    refute_received {:core_asked, _, _}
  end

  test "refuses a request beyond the renewal bounds before verifying anything", %{keys: keys} do
    bytes = EdgeRecordV1.encode(Factory.record(keys.private))
    too_many = for sequence <- 1..(EdgeDeliveryGrants.max_records() + 1), do: {sequence, bytes}

    assert {:error, :invalid_argument, _} = EdgeDeliveryGrants.late(request(too_many), @identity)
    assert {:error, :invalid_argument, _} = EdgeDeliveryGrants.late(request([{1, bytes}, {1, bytes}]), @identity)
    refute_received {:core_asked, _, _}
  end

  defp request(records) do
    %Monitoring.EdgeDeliveryGrantRequest{
      spool_id: @spool_id,
      records:
        Enum.map(records, fn {sequence, bytes} ->
          %Monitoring.EdgeDeliveryGrantRecord{sequence: sequence, record_bytes: bytes}
        end)
    }
  end
end
