defmodule ServiceRadar.Edge.Projectors.TelemetryBatchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias Serviceradar.Agent.Addon.V1.TelemetrySource
  alias ServiceRadar.Edge.Projectors.TelemetryBatch, as: TelemetryBatchProjector
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.StatusHandler

  @moduletag :db_free

  @event_id Ecto.UUID.dump!("00000000-0000-4000-8000-000000000101")
  @assignment_id Ecto.UUID.dump!("00000000-0000-4000-8000-000000000202")
  @network_scope_id Ecto.UUID.dump!("00000000-0000-4000-8000-000000000303")

  defp build_record(records, producer_type \\ "plugin", producer_id \\ "assignment-horizon-1") do
    batch = %TelemetryBatch{
      source: %TelemetrySource{
        source_type: "horizon-feed",
        source_instance: producer_id,
        metadata: %{
          "serviceradar.producer_type" => producer_type,
          "serviceradar.producer_id" => producer_id
        }
      },
      records: records
    }

    body = TelemetryBatch.encode(batch)

    %EdgeRecordV1{
      event_id: @event_id,
      network_scope_id: @network_scope_id,
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      projected_row_count: length(records),
      payload: body,
      output_contract: %EdgeOutputContractRef{
        contract_id: "serviceradar.telemetry.batch",
        contract_version: 1
      },
      producer_context: %EdgeProducerContext{
        origin_principal_id: "agent-horizon-1",
        producer_assignment_id: @assignment_id,
        authority_epoch: 1
      }
    }
  end

  defp publish_opts(request_fn, extra \\ []) do
    Keyword.merge(
      [
        check_grant_fn: fn _assignment_id, _agent_id, _contract_id, _scope_id, _epoch -> :ok end,
        partition_lookup_fn: fn _scope_id -> {:ok, %Partition{slug: "default"}} end,
        request: request_fn
      ],
      extra
    )
  end

  test "admits EXTERNAL_TOPOLOGY_V1 for both plugin and addon producers at decode" do
    snapshot =
      ~s({"schema_version":1,"generated_at":"2026-11-27T00:00:00Z","nodes":[{"id":"asn:64496","kind":"ASN"}],"edges":[]})

    for producer_type <- ["plugin", "addon"] do
      record =
        build_record(
          [
            %TelemetryRecord{
              event_id: "topo-1",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_EXTERNAL_TOPOLOGY_V1,
              payload: snapshot
            }
          ],
          producer_type,
          "producer-1"
        )

      assert {:ok, {%TelemetryBatch{}, _body, %{type: ^producer_type, id: "producer-1"}}} =
               TelemetryBatchProjector.decode(record)
    end
  end

  test "publishes EXTERNAL_TOPOLOGY_V1 verbatim to JetStream and skips StatusIngestor" do
    snapshot =
      ~s({"schema_version":1,"generated_at":"2026-11-27T00:00:00Z","ttl_secs":300,"nodes":[{"id":"asn:64496","kind":"ASN"}],"edges":[]})

    record =
      build_record([
        %TelemetryRecord{
          event_id: "topo-shard-1",
          payload_kind: :TELEMETRY_PAYLOAD_KIND_EXTERNAL_TOPOLOGY_V1,
          payload: snapshot
        }
      ])

    assert {:ok, decoded} = TelemetryBatchProjector.decode(record)

    prev = Application.get_env(:serviceradar_core, StatusHandler, [])

    on_exit(fn ->
      if prev == [],
        do: Application.delete_env(:serviceradar_core, StatusHandler),
        else: Application.put_env(:serviceradar_core, StatusHandler, prev)
    end)

    parent = self()

    Application.put_env(:serviceradar_core, StatusHandler,
      addon_telemetry_publisher: fn subject, payload ->
        send(parent, {:unexpected_status_ingestor, subject, payload})
        :ok
      end
    )

    request_fn = fn subject, body, opts ->
      send(parent, {:js_publish, subject, body, opts})
      {:ok, %{body: ~s({"stream":"horizon_topology","seq":1})}}
    end

    assert :ok = TelemetryBatchProjector.publish(record, decoded, publish_opts(request_fn))

    assert_received {:js_publish, "serviceradar.horizon.topology.snapshot", ^snapshot, js_opts}
    assert {"Nats-Msg-Id", msg_id} = List.keyfind(js_opts[:headers], "Nats-Msg-Id", 0)
    assert is_binary(msg_id) and msg_id != ""
    refute_received {:unexpected_status_ingestor, _subject, _payload}
  end

  test "mixed OCSF_EVENT + EXTERNAL_TOPOLOGY_V1 batch routes OCSF to StatusIngestor and topology to JetStream" do
    snapshot =
      ~s({"schema_version":1,"generated_at":"2026-11-27T00:00:00Z","nodes":[],"edges":[]})

    ocsf = ~s({"class_uid":4003,"message":"horizon.outage"})

    record =
      build_record([
        %TelemetryRecord{
          event_id: "ocsf-1",
          payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
          payload: ocsf
        },
        %TelemetryRecord{
          event_id: "topo-2",
          payload_kind: :TELEMETRY_PAYLOAD_KIND_EXTERNAL_TOPOLOGY_V1,
          payload: snapshot
        }
      ])

    assert {:ok, decoded} = TelemetryBatchProjector.decode(record)

    prev = Application.get_env(:serviceradar_core, StatusHandler, [])

    on_exit(fn ->
      if prev == [],
        do: Application.delete_env(:serviceradar_core, StatusHandler),
        else: Application.put_env(:serviceradar_core, StatusHandler, prev)
    end)

    parent = self()

    Application.put_env(:serviceradar_core, StatusHandler,
      addon_telemetry_publisher: fn subject, payload ->
        send(parent, {:status_routed, subject, payload})
        :ok
      end
    )

    request_fn = fn subject, body, opts ->
      send(parent, {:js_publish, subject, body, opts})
      {:ok, %{body: ~s({"stream":"horizon_topology","seq":2})}}
    end

    log =
      capture_log(fn ->
        assert :ok = TelemetryBatchProjector.publish(record, decoded, publish_opts(request_fn))
      end)

    assert_received {:js_publish, "serviceradar.horizon.topology.snapshot", ^snapshot, _opts}
    assert_received {:status_routed, "events.ocsf.processed", routed}
    assert Jason.decode!(routed)["class_uid"] == 4003
    refute_received {:status_routed, _other_subject, _other_payload}
    refute log =~ "unrecognized payload kind"
  end

  test "enforces OutputGrants.check_current refusal before publishing EXTERNAL_TOPOLOGY_V1" do
    snapshot = ~s({"schema_version":1,"generated_at":"2026-11-27T00:00:00Z","nodes":[]})

    record =
      build_record([
        %TelemetryRecord{
          event_id: "topo-revoked",
          payload_kind: :TELEMETRY_PAYLOAD_KIND_EXTERNAL_TOPOLOGY_V1,
          payload: snapshot
        }
      ])

    assert {:ok, decoded} = TelemetryBatchProjector.decode(record)

    parent = self()

    request_fn = fn subject, body, opts ->
      send(parent, {:js_publish, subject, body, opts})
      {:ok, %{body: ~s({"stream":"horizon_topology","seq":1})}}
    end

    opts =
      publish_opts(request_fn,
        check_grant_fn: fn _, _, _, _, _ -> {:error, :output_grant_not_current} end
      )

    assert {:refused, :output_grant_not_current} =
             TelemetryBatchProjector.publish(record, decoded, opts)

    refute_received {:js_publish, _subject, _body, _opts}
  end

  test "rejects invalid or raw-hop EXTERNAL_TOPOLOGY_V1 payloads with warning and telemetry" do
    handler_id = "topo-decode-failed-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:serviceradar, :plugin_topology, :decode_failed],
      fn _event, measurements, metadata, _config ->
        send(parent, {:topo_decode_failed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    invalid_payloads = [
      ~s({"schema_version":2,"generated_at":"2026-11-27T00:00:00Z"}),
      ~s({"schema_version":1,"generated_at":"","nodes":[]}),
      ~s({"schema_version":1,"generated_at":"2026-11-27T00:00:00Z","nodes":"bad"}),
      ~s({"schema_version":1,"generated_at":"2026-11-27T00:00:00Z","raw_hops":[]}),
      ~s({"schema_version":1,"generated_at":"2026-11-27T00:00:00Z","round_id":"r1"}),
      "not-json"
    ]

    for bad_payload <- invalid_payloads do
      record =
        build_record([
          %TelemetryRecord{
            event_id: "topo-bad",
            payload_kind: :TELEMETRY_PAYLOAD_KIND_EXTERNAL_TOPOLOGY_V1,
            payload: bad_payload
          }
        ])

      assert {:ok, decoded} = TelemetryBatchProjector.decode(record)

      request_fn = fn subject, body, opts ->
        send(parent, {:js_publish, subject, body, opts})
        {:ok, %{body: ~s({"stream":"horizon_topology","seq":1})}}
      end

      log =
        capture_log(fn ->
          assert :ok = TelemetryBatchProjector.publish(record, decoded, publish_opts(request_fn))
        end)

      assert log =~ "Plugin external topology validation failed"
      assert_received {:topo_decode_failed, %{count: 1}, %{agent_id: "agent-horizon-1"}}
      refute_received {:js_publish, _subject, _body, _opts}
    end
  end

  test "returns retryable error with deterministic msg_id when JetStream publish fails" do
    snapshot = ~s({"schema_version":1,"generated_at":"2026-11-27T00:00:00Z","nodes":[]})

    record =
      build_record([
        %TelemetryRecord{
          event_id: "topo-fail",
          payload_kind: :TELEMETRY_PAYLOAD_KIND_EXTERNAL_TOPOLOGY_V1,
          payload: snapshot
        }
      ])

    assert {:ok, decoded} = TelemetryBatchProjector.decode(record)

    parent = self()

    failing_request = fn subject, body, opts ->
      send(parent, {:js_attempt, subject, body, opts})
      {:error, :not_connected}
    end

    assert {:error, {:telemetry_external_topology_publish_failed, :not_connected}} =
             TelemetryBatchProjector.publish(record, decoded, publish_opts(failing_request))

    assert {:error, {:telemetry_external_topology_publish_failed, :not_connected}} =
             TelemetryBatchProjector.publish(record, decoded, publish_opts(failing_request))

    assert_received {:js_attempt, "serviceradar.horizon.topology.snapshot", ^snapshot, opts1}
    assert_received {:js_attempt, "serviceradar.horizon.topology.snapshot", ^snapshot, opts2}
    assert opts1[:headers] == opts2[:headers]
  end
end
