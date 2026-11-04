defmodule ServiceRadarAgentGateway.EdgeDeliveryGrantsTest do
  use ExUnit.Case, async: false

  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias ServiceRadarAgentGateway.EdgeDeliveryGrants
  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordFactory, as: Factory

  # A synthetic UUIDv7 spool id.
  @spool_id <<0x0190_0000_0004::48, 7::4, 0x0AB::12, 2::2, 0xAB::62>>
  @identity %{component_id: "agent-1", component_type: :agent}
  @grant %EdgeSignedCapabilityV1{issuer_id: "serviceradar-core", signature: :binary.copy(<<1>>, 64)}

  setup do
    keys = Factory.keypair()
    test_pid = self()

    Application.put_env(:serviceradar_agent_gateway, :edge_delivery_grant_rpc, fn agent_id, items ->
      send(test_pid, {:core_asked, agent_id, items})

      {:ok,
       Enum.map(items, fn item ->
         if item.sequence == 99,
           do: %{sequence: item.sequence, delivery_capability: nil, refusal: :assignment_revoked},
           else: %{sequence: item.sequence, delivery_capability: @grant, refusal: nil}
       end)}
    end)

    :ok = EdgeRecordTrust.install(Factory.trust_document(keys.public))

    on_exit(fn ->
      Application.delete_env(:serviceradar_agent_gateway, :edge_delivery_grant_rpc)
      EdgeRecordTrust.clear()
    end)

    %{keys: keys}
  end

  test "asks core about a verified record by its own coordinates and returns core's grant", %{keys: keys} do
    now = System.os_time(:nanosecond)
    hour = Factory.hour_nanos()
    lapsed = Factory.record(keys.private, not_before: now - 3 * hour, expires: now - 2 * hour)
    bytes = EdgeRecordV1.encode(lapsed)

    assert {:ok, %Monitoring.EdgeDeliveryGrantResponse{results: [result]}} =
             EdgeDeliveryGrants.renew(request([{7, bytes}]), @identity)

    assert result == %Monitoring.EdgeDeliveryGrantResult{sequence: 7, delivery_capability: @grant, refusal: ""}

    assert_received {:core_asked, "agent-1", [item]}

    assert item == %{
             sequence: 7,
             spool_id: @spool_id,
             event_id: lapsed.event_id,
             record_sha256: :crypto.hash(:sha256, bytes),
             network_scope_id: Factory.network_scope_id(),
             producer_assignment_id: Factory.producer_assignment_id(),
             run_shard: lapsed.producer_context.run_shard
           }
  end

  test "refuses, without asking core, a record the agent did not produce or that does not verify", %{keys: keys} do
    foreign = Factory.record(keys.private, principal: "agent-2")
    forged = Factory.record(Factory.keypair().private)

    assert {:ok, %Monitoring.EdgeDeliveryGrantResponse{results: results}} =
             EdgeDeliveryGrants.renew(
               request([{1, EdgeRecordV1.encode(foreign)}, {2, EdgeRecordV1.encode(forged)}]),
               @identity
             )

    assert Enum.map(results, &{&1.sequence, &1.delivery_capability, &1.refusal}) == [
             {1, nil, "identity_conflict"},
             {2, nil, "production.signature"}
           ]

    refute_received {:core_asked, _, _}
  end

  test "relays core's refusal for an authority the agent no longer holds", %{keys: keys} do
    bytes = EdgeRecordV1.encode(Factory.record(keys.private))

    assert {:ok, %Monitoring.EdgeDeliveryGrantResponse{results: [result]}} =
             EdgeDeliveryGrants.renew(request([{99, bytes}]), @identity)

    assert {result.delivery_capability, result.refusal} == {nil, "assignment_revoked"}
  end

  test "a record signed by a compromise-revoked key gets no grant: it needs none to reach quarantine", %{
    keys: keys
  } do
    :ok = EdgeRecordTrust.install(Factory.trust_document(keys.public, status: "historically_revoked"))

    assert {:ok, %Monitoring.EdgeDeliveryGrantResponse{results: [result]}} =
             EdgeDeliveryGrants.renew(request([{1, EdgeRecordV1.encode(Factory.record(keys.private))}]), @identity)

    assert result.refusal == "key_historically_revoked"
    refute_received {:core_asked, _, _}
  end

  test "refuses a request beyond its bounds before verifying anything", %{keys: keys} do
    bytes = EdgeRecordV1.encode(Factory.record(keys.private))
    too_many = for sequence <- 1..(EdgeDeliveryGrants.max_records() + 1), do: {sequence, bytes}

    assert {:error, :invalid_argument, _} = EdgeDeliveryGrants.renew(request(too_many), @identity)
    assert {:error, :invalid_argument, _} = EdgeDeliveryGrants.renew(request([{1, bytes}, {1, bytes}]), @identity)

    assert {:error, :invalid_argument, _} =
             EdgeDeliveryGrants.renew(%{request([{1, bytes}]) | spool_id: :binary.copy(<<0>>, 16)}, @identity)

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
