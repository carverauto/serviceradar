defmodule ServiceRadar.EventWriter.WasmSyntheticJourneyProjectionTest do
  @moduledoc """
  DB-free end-to-end projection tests for `http-synthetic-journey` edge payloads:
  `ContractCatalog`, `WireDecode`, `WasmPluginResult.{decode,publish}`,
  `TelemetryBatch.decode/1`, `Metrics.parse_message/1`,
  `MetricEnvelope.decode_rows_count/2`, and `StarRocks.Rows.encode/2`.
  """
  use ExUnit.Case, async: true

  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias Serviceradar.Agent.Addon.V1.TelemetrySource
  alias ServiceRadar.Analytics.StarRocks.Rows, as: StarRocksRows
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrant
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.Projectors.TelemetryBatch, as: TelemetryBatchProjector
  alias ServiceRadar.Edge.Projectors.WasmPluginResult, as: WasmPluginResultProjector
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.PluginDisplayInstructionV1
  alias Serviceradar.Edge.V1.PluginResultProvenanceV1
  alias Serviceradar.Edge.V1.WasmPluginResultBatchV1
  alias Serviceradar.Edge.V1.WasmPluginResultItemV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.Observability.MetricEnvelope
  alias ServiceRadar.Observability.ServiceStatus
  alias ServiceRadar.SweepJobs.ExecutionSlots

  @moduletag :db_free

  @plugin_results_contract "serviceradar.plugin_results.batch"
  @telemetry_batch_contract "serviceradar.telemetry.batch"
  @web_property_id "00000000-0000-4000-8000-000000000772"
  @agent_id "agent-synthetic-e2e"
  @partition_id "00000000-0000-4000-8000-000000000701"
  @assignment_id "00000000-0000-4000-8000-000000000703"
  @point_time_ns 1_781_222_400_000_000_000

  test "ContractCatalog resolves both standing-grant contracts for synthetic journeys" do
    assert {:ok, %{projector: WasmPluginResultProjector, write_bytes_per_row: 16_384}} =
             ContractCatalog.fetch({@plugin_results_contract, 1})

    assert {:ok, %{projector: TelemetryBatchProjector, write_bytes_per_row: 8_192}} =
             ContractCatalog.fetch({@telemetry_batch_contract, 1})
  end

  test "WireDecode and WasmPluginResult preserve waterfall widgets and web_property_id" do
    table_json =
      Jason.encode!(%{
        "01. login" => "OK | 302 | 11.0ms (dns=1.0 connect=2.0 tls=3.0 ttfb=4.0 xfer=1.0)",
        "02. redirect-callback" =>
          "OK | 200 | 6.5ms (dns=0.5 connect=1.0 tls=1.5 ttfb=3.0 xfer=0.5)"
      })

    item = %WasmPluginResultItemV1{
      schema_version: 1,
      status: :PLUGIN_RESULT_STATUS_OK,
      summary: "journey tls-sso-journey OK (2/2 steps in 17.5ms)",
      service_name: "http-synthetic-journey",
      service_type: "plugin",
      labels: %{
        "journey" => "tls-sso-journey",
        "web_property_id" => @web_property_id,
        "assignment_id" => @assignment_id,
        "plugin_id" => "http-synthetic-journey"
      },
      display: [
        %PluginDisplayInstructionV1{
          widget: "stat_card",
          label: "Journey Status",
          value: "OK",
          tone: "success"
        },
        %PluginDisplayInstructionV1{
          widget: "stat_card",
          label: "Total Duration",
          value: "17.5ms",
          tone: "success"
        },
        %PluginDisplayInstructionV1{
          widget: "table",
          layout: "full",
          data_json: table_json
        }
      ],
      observed_at_unix_nano: @point_time_ns
    }

    provenance = %PluginResultProvenanceV1{
      assignment_id: @assignment_id,
      plugin_id: "http-synthetic-journey",
      plugin_package_id: "pkg-http-synthetic-journey",
      plugin_version: "0.1.0",
      content_hash: String.duplicate("ab", 32)
    }

    payload =
      WasmPluginResultBatchV1.encode(%WasmPluginResultBatchV1{
        provenance: provenance,
        results: [item]
      })

    record_bytes = build_signed_edge_record(@plugin_results_contract, payload, 1, 16_384)
    assert {:ok, _validated} = RecordValidate.validate_bytes(record_bytes)
    assert {:ok, %EdgeRecordV1{} = decoded_record} = WireDecode.decode_record(record_bytes)

    assert {:ok, {%WasmPluginResultBatchV1{} = decoded_batch, decoded_provenance}} =
             WasmPluginResultProjector.decode(decoded_record)

    assert decoded_provenance["plugin_id"] == "http-synthetic-journey"

    test_pid = self()

    persistence = %{
      remap_service_name: fn status -> {:ok, status} end,
      insert_status: fn status_row, _actor ->
        send(test_pid, {:status_row, status_row})
        {:ok, struct(ServiceStatus, status_row), :inserted}
      end,
      persist_applied: fn status_row, _payload, _outcomes, _actor ->
        {:ok, struct(ServiceStatus, status_row)}
      end,
      persist_settled: fn status_row, _payload, _outcomes, _actor ->
        {:ok, struct(ServiceStatus, status_row)}
      end,
      persist_failed: fn status_row, _payload, _errors, _handlers, _actor ->
        {:ok, struct(ServiceStatus, status_row)}
      end,
      publish_status: fn _status -> :ok end
    }

    opts = [
      check_grant_fn: fn _, _, _, _, _ -> :ok end,
      partition_lookup_fn: fn _id -> {:ok, %Partition{slug: "partition-alpha"}} end,
      agent_lookup_fn: fn _id -> {:ok, %Agent{capabilities: ["http_request"]}} end,
      ingestor_opts: [handlers: [], persistence: persistence]
    ]

    assert :ok =
             WasmPluginResultProjector.publish(
               decoded_record,
               {decoded_batch, decoded_provenance},
               opts
             )

    assert_receive {:status_row, status_row}
    assert status_row.available == true
    assert status_row.service_type == "plugin"
    assert status_row.partition == "partition-alpha"

    details = Jason.decode!(status_row.details)
    assert details["labels"]["web_property_id"] == @web_property_id
    assert details["labels"]["journey"] == "tls-sso-journey"
    assert is_map(details["_serviceradar_plugin_result"])

    widgets = Enum.map(details["display"], & &1["widget"])
    assert "stat_card" in widgets
    assert "table" in widgets

    table_widget = Enum.find(details["display"], &(&1["widget"] == "table"))
    assert table_widget["data"]["01. login"] =~ "302"
    assert table_widget["data"]["02. redirect-callback"] =~ "200"
  end

  test "TelemetryBatch -> Metrics -> MetricEnvelope -> StarRocks.Rows preserves synthetic metrics and web_property_id" do
    step_attrs = %{
      "journey" => "tls-sso-journey",
      "step" => "login",
      "step_index" => "0",
      "method" => "POST",
      "host" => "127.0.0.1",
      "status_code" => "302",
      "connection_reused" => "false",
      "protocol" => "HTTP/1.1",
      "web_property_id" => @web_property_id
    }

    journey_attrs = %{
      "journey" => "tls-sso-journey",
      "web_property_id" => @web_property_id
    }

    raw_metric_batch = %MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{
        service_name: "tls-sso-journey",
        service_type: "wasm-plugin",
        device_id: "sr:device-pipeline-1",
        target_device_ip: "198.51.100.20",
        attributes: entries(journey_attrs)
      },
      ingest_identity: %IngestIdentity{
        source: "plugin-metrics",
        payload_kind: "serviceradar.metric.v1",
        producer_id: "tls-sso-journey",
        producer_kind: "wasm-plugin"
      },
      emitted_at_unix_nano: @point_time_ns,
      metrics: [
        synthetic_metric("synthetic.journey.available", "1", 1.0, journey_attrs),
        synthetic_metric("synthetic.journey.duration_ms", "ms", 17.5, journey_attrs),
        synthetic_metric("synthetic.journey.steps_completed", "{step}", 2.0, journey_attrs),
        synthetic_metric("synthetic.step.duration_ms", "ms", 11.0, step_attrs),
        synthetic_metric("synthetic.step.dns_ms", "ms", 1.0, step_attrs),
        synthetic_metric("synthetic.step.connect_ms", "ms", 2.0, step_attrs),
        synthetic_metric("synthetic.step.tls_ms", "ms", 3.0, step_attrs),
        synthetic_metric("synthetic.step.ttfb_ms", "ms", 4.0, step_attrs),
        synthetic_metric("synthetic.step.transfer_ms", "ms", 1.0, step_attrs),
        synthetic_metric("synthetic.step.tls_cert_days_remaining", "d", 45.0, step_attrs)
      ]
    }

    tele_batch = %TelemetryBatch{
      source: %TelemetrySource{
        source_type: "plugin",
        source_instance: "tls-sso-journey",
        metadata: %{
          "serviceradar.producer_type" => "plugin",
          "serviceradar.producer_id" => @assignment_id
        }
      },
      records: [
        %TelemetryRecord{
          event_id: "journey-tls-sso-1",
          observed_time_unix_nano: @point_time_ns,
          payload_kind: :TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS,
          payload: MetricBatch.encode(raw_metric_batch)
        }
      ]
    }

    edge_bytes =
      build_signed_edge_record(
        @telemetry_batch_contract,
        TelemetryBatch.encode(tele_batch),
        1,
        8_192
      )

    assert {:ok, %EdgeRecordV1{} = decoded_record} = WireDecode.decode_record(edge_bytes)

    assert {:ok,
            {%TelemetryBatch{} = decoded_batch, _body, %{type: "plugin", id: @assignment_id}}} =
             TelemetryBatchProjector.decode(decoded_record)

    [tele_rec] = decoded_batch.records

    assert {:ok, %MetricBatch{} = decoded_metrics} =
             WireDecode.decode_metric_batch(tele_rec.payload)

    # Mirror TelemetryBatchProjector.attest/5 stamps before MetricEnvelope ingestion.
    attested = %{
      decoded_metrics
      | resource: %{
          decoded_metrics.resource
          | agent_id: @agent_id,
            gateway_id: "",
            partition: "default",
            service_name: "plugin-telemetry",
            service_type: "plugin"
        },
        ingest_identity: %{
          decoded_metrics.ingest_identity
          | source: "wasm-plugin",
            payload_kind: "serviceradar.metric.v1",
            producer_id: @assignment_id,
            producer_kind: "plugin",
            attested_by: @agent_id
        },
        ingress_id: "00000000-0000-4000-8000-000000000999",
        ingress_timestamp_unix_nano: @point_time_ns
    }

    attested_bytes = MetricBatch.encode(attested)

    assert {:ok, envelope_rows, 10} =
             MetricEnvelope.decode_rows_count(attested_bytes,
               plugin_producer: true,
               agent_host_producer: true
             )

    parsed_rows =
      Metrics.parse_message(%{
        data: attested_bytes,
        metadata: %{subject: "metrics.timeseries.synthetic.synthetic_journey_available"}
      })

    assert length(parsed_rows) == 10
    assert Enum.all?(envelope_rows, &(&1.metric_type == "synthetic"))
    assert Enum.all?(envelope_rows, &(&1.tags["web_property_id"] == @web_property_id))
    assert Enum.all?(envelope_rows, &(&1.tags["journey"] == "tls-sso-journey"))
    assert Enum.all?(envelope_rows, &(is_binary(&1.series_key) and &1.series_key != ""))

    starrocks_rows = StarRocksRows.encode(:metrics, envelope_rows)
    assert length(starrocks_rows) == 10

    available_sr =
      Enum.find(starrocks_rows, &(&1["metric_name"] == "synthetic.journey.available"))

    assert available_sr["metric_type"] == "synthetic"
    assert available_sr["value"] == 1.0
    assert Jason.decode!(available_sr["tags"])["web_property_id"] == @web_property_id

    step_sr = Enum.find(starrocks_rows, &(&1["metric_name"] == "synthetic.step.tls_ms"))
    assert step_sr["metric_type"] == "synthetic"
    step_tags = Jason.decode!(step_sr["tags"])
    assert step_tags["step"] == "login"
    assert step_tags["web_property_id"] == @web_property_id
  end

  defp synthetic_metric(name, unit, value, attrs) do
    %Metric{
      name: name,
      metric_type: "synthetic",
      kind: :METRIC_KIND_GAUGE,
      unit: unit,
      points: [
        %MetricPoint{
          value: value,
          observed_at_unix_nano: @point_time_ns,
          attributes: entries(attrs)
        }
      ]
    }
  end

  defp entries(map) do
    Enum.map(map, fn {k, v} -> %StringMapEntry{key: k, value: v} end)
  end

  defp build_signed_edge_record(contract_id, payload, row_count, write_bytes_per_row) do
    grant = %OutputGrant{
      id: "00000000-0000-4000-8000-000000000702",
      agent_id: @agent_id,
      contract_id: contract_id,
      network_scope_id: @partition_id,
      authority_epoch: 1,
      state: :active
    }

    now = DateTime.utc_now()
    {:ok, catalog_entry} = ContractCatalog.fetch({contract_id, 1})

    contract = %{
      contract_id: contract_id,
      contract_version: 1,
      contract_bundle_sha256: :crypto.hash(:sha256, contract_id),
      registry_epoch: 1,
      registry_snapshot_sha256: :crypto.hash(:sha256, "registry"),
      cost_model_version: catalog_entry.cost_model_version,
      max_projected_row_count: catalog_entry.max_projected_rows,
      max_projected_write_bytes:
        catalog_entry.max_projected_rows * catalog_entry.write_bytes_per_row
    }

    key = IssuerKey.from_seed(:binary.copy(<<0x5B>>, 32))
    production = OutputGrants.production_capability(grant, contract, key, now)
    {:production, claims} = production.claims

    record = %EdgeRecordV1{
      event_id: Ecto.UUID.dump!(ExecutionSlots.mint_id(now)),
      output_contract:
        struct(
          EdgeOutputContractRef,
          Map.take(claims, [
            :contract_id,
            :contract_version,
            :contract_bundle_sha256,
            :registry_epoch,
            :registry_snapshot_sha256,
            :effective_grant_sha256
          ])
        ),
      production_capability: production,
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      encoded_size: byte_size(payload),
      uncompressed_size: byte_size(payload),
      payload_sha256: :crypto.hash(:sha256, payload),
      producer_context: %EdgeProducerContext{
        origin_kind: :EDGE_ORIGIN_KIND_AGENT,
        origin_principal_id: @agent_id,
        producer_instance_id: @agent_id,
        producer_assignment_id: claims.producer_assignment_id,
        authority_epoch: claims.authority_epoch,
        run_id: claims.run_id,
        run_shard: 0,
        scope_id: claims.scope_id,
        scope_sha256: claims.scope_sha256,
        package_id: claims.package_id,
        package_sha256: claims.package_sha256
      },
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      network_scope_id: Ecto.UUID.dump!(@partition_id),
      projected_row_count: row_count,
      projected_write_bytes: row_count * write_bytes_per_row,
      cost_model_version: 1,
      payload: payload
    }

    record = %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}
    EdgeRecordV1.encode(record)
  end
end
