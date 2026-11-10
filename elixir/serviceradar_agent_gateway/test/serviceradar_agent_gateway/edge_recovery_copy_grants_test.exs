defmodule ServiceRadarAgentGateway.EdgeRecoveryCopyGrantsTest do
  use ExUnit.Case, async: false

  alias Monitoring.EdgeRecoveryCopyGrantItem
  alias Monitoring.EdgeRecoveryCopyGrantRequest
  alias Monitoring.EdgeRecoveryQuery
  alias ServiceRadar.Edge.RecoveryAttribution
  alias ServiceRadar.Edge.RecoveryControl
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.EdgeRecoveryCopyGrants
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordFactory, as: Factory

  @identity %{component_id: "agent-1", component_type: :agent}

  setup do
    keys = Factory.keypair()
    entry = Factory.contract_entry(%{contract_id: "serviceradar.metrics.batch"})
    epoch = Factory.registry_epoch(entries: [entry])
    contract = Factory.contract_ref(epoch, {entry.contract_id, 1})
    document = Factory.trust_document(keys.public, contract_registry: Factory.registry_member([epoch]))
    :ok = EdgeRecordTrust.install(document)
    parent = self()

    Application.put_env(:serviceradar_agent_gateway, :edge_recovery_control_rpc, fn module, function, args, _timeout ->
      send(parent, {:core, module, function, args})

      {:ok,
       %Monitoring.EdgeDeliveryGrantResponse{
         results: [
           %Monitoring.EdgeDeliveryGrantResult{
             sequence: 7,
             refusal: "synthetic_core_refusal"
           }
         ]
       }}
    end)

    on_exit(fn ->
      EdgeRecordTrust.clear()
      Application.delete_env(:serviceradar_agent_gateway, :edge_recovery_control_rpc)
    end)

    payload =
      MetricBatch.encode(%MetricBatch{
        schema_version: "serviceradar.metric.v1",
        ingest_identity: %IngestIdentity{source: "sysmon-metrics"},
        metrics: [%Metric{name: "cpu.usage_percent", metric_type: "sysmon.cpu"}]
      })

    now = System.system_time(:nanosecond)

    record =
      Factory.record(keys.private,
        output_contract: contract,
        payload: payload,
        not_before: now - 3 * Factory.hour_nanos(),
        expires: now - 2 * Factory.hour_nanos()
      )

    request = %EdgeRecoveryCopyGrantRequest{
      recovery: %EdgeRecoveryQuery{
        network_scope_id: Factory.network_scope_id(),
        recovery_id: Factory.uuidv7()
      },
      records: [%EdgeRecoveryCopyGrantItem{prior_sequence: 2, new_sequence: 7, record_bytes: EdgeRecordV1.encode(record)}]
    }

    %{request: request, record: record, keys: keys, contract: contract}
  end

  test "expired typed record crosses only the authenticated historical boundary", ctx do
    assert {:ok, %{results: [%{sequence: 7, refusal: "synthetic_core_refusal"}]}} =
             EdgeRecoveryCopyGrants.renew(ctx.request, @identity)

    assert_received {:core, RecoveryControl, :renew_copies, ["agent-1", query, [item]]}
    assert query == ctx.request.recovery
    assert {item.prior_sequence, item.new_sequence} == {2, 7}

    assert %{classification: {:attributed_passive, %{identity: %{source: nil}}}} =
             RecoveryAttribution.classification(item.attribution)
  end

  test "wrong scope, invalid typed body and compromised signatures never reach core", ctx do
    [original] = ctx.request.records
    malformed = Factory.record(ctx.keys.private, output_contract: ctx.contract, payload: <<255>>)
    foreign = %{ctx.request | recovery: %{ctx.request.recovery | network_scope_id: Factory.uuidv7()}}

    for request <- [foreign, %{ctx.request | records: [%{original | record_bytes: EdgeRecordV1.encode(malformed)}]}] do
      assert {:ok, %{results: [%{delivery_capability: nil, refusal: "copy_authority_refused"}]}} =
               EdgeRecoveryCopyGrants.renew(request, @identity)

      refute_received {:core, _, _, _}
    end

    :ok = EdgeRecordTrust.install(Factory.trust_document(ctx.keys.public, status: "historically_revoked"))

    assert {:ok, %{results: [%{delivery_capability: nil, refusal: "copy_authority_refused"}]}} =
             EdgeRecoveryCopyGrants.renew(ctx.request, @identity)

    refute_received {:core, _, _, _}
  end

  test "duplicate coordinates and excessive bytes refuse before authority work", ctx do
    [item] = ctx.request.records

    for records <- [[item, item], [%{item | record_bytes: :binary.copy(<<0>>, 2 * 1024 * 1024 + 1)}]] do
      assert {:error, :invalid_argument, _} =
               EdgeRecoveryCopyGrants.renew(%{ctx.request | records: records}, @identity)
    end

    refute_received {:core, _, _, _}
  end
end
