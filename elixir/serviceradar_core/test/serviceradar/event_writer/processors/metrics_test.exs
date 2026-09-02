defmodule ServiceRadar.EventWriter.Processors.MetricsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.Metrics
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.Observability.MetricEnvelope
  alias ServiceRadar.Observability.TimeseriesSeriesKey

  @point_time 1_781_222_400_000_000_000
  @decode_completed [:serviceradar, :metric_envelope, :decode, :completed]
  @decode_failed [:serviceradar, :metric_envelope, :decode, :failed]
  @schema_version [:serviceradar, :metric_envelope, :schema_version]

  test "parses sysmon protobuf metrics as timeseries rows" do
    [row] =
      Metrics.parse_message(%{
        data:
          metric_batch([
            gauge_metric("memory.used_percent", "sysmon.memory", 50.0, "%",
              tags: %{"host_id" => "host-1"}
            )
          ]),
        metadata: %{subject: "metrics.sysmon.memory"}
      })

    assert %{
             gateway_id: "gateway-1",
             agent_id: "agent-1",
             metric_name: "memory.used_percent",
             metric_type: "sysmon.memory",
             value: 50.0,
             unit: "%",
             series_key: series_key
           } = row

    assert is_binary(series_key)
    assert row.tags["source"] == "sysmon-metrics"
    assert row.metadata["schema"] == "serviceradar.metric.v1"
    assert row.metadata["kind"] == "gauge"
  end

  test "parses SNMP counter protobuf metrics with monotonic semantics" do
    [row] =
      Metrics.parse_message(%{
        data:
          metric_batch([
            %Metric{
              name: "ifHCInOctets",
              metric_type: "snmp",
              kind: :METRIC_KIND_SUM,
              temporality: :METRIC_TEMPORALITY_CUMULATIVE,
              is_monotonic: true,
              unit: "By",
              counter_width: 64,
              tags: entries(%{"target" => "router-a", "host" => "10.0.0.20"}),
              metadata: entries(%{"oid" => ".1.3.6.1.2.1.31.1.1.1.6.7"}),
              points: [
                %MetricPoint{
                  value: 1234.5,
                  raw_value: "1234",
                  raw_value_type: :METRIC_VALUE_TYPE_UINT64,
                  observed_at_unix_nano: @point_time,
                  if_index: 7,
                  interface_uid: "ifindex:7",
                  attributes: entries(%{"target" => "router-a", "host" => "10.0.0.20"})
                }
              ]
            }
          ]),
        metadata: %{subject: "metrics.snmp.interface.ifHCInOctets"}
      })

    assert %{
             metric_name: "ifHCInOctets",
             metric_type: "snmp",
             value: 1234.5,
             target_device_ip: "10.0.0.20",
             if_index: 7
           } = row

    assert row.tags["interface_uid"] == "ifindex:7"
    assert row.metadata["kind"] == "sum"
    assert row.metadata["temporality"] == "cumulative"
    assert row.metadata["is_monotonic"] == true
    assert row.metadata["raw_value"] == "1234"
    assert row.metadata["counter_width"] == 64
  end

  test "parses plugin scalar protobuf metrics" do
    [row] =
      Metrics.parse_message(%{
        data:
          metric_batch([
            gauge_metric("proxmox_guest_cpu_ratio_max", "cpu", 0.91, "ratio",
              tags: %{"producer_id" => "proxmox-inventory"},
              metadata: %{"status" => "WARNING"}
            )
          ]),
        metadata: %{subject: "metrics.timeseries.cpu.proxmox_guest_cpu_ratio_max"}
      })

    assert %{
             metric_name: "proxmox_guest_cpu_ratio_max",
             metric_type: "cpu",
             value: 0.91,
             series_key: series_key
           } = row

    assert is_binary(series_key)
    assert row.tags["producer_id"] == "proxmox-inventory"
    assert row.metadata["status"] == "WARNING"
  end

  test "preserves multi-point protobuf metric order and point overrides" do
    rows =
      Metrics.parse_message(%{
        data:
          metric_batch([
            %Metric{
              name: "custom.temperature_celsius",
              metric_type: "environment.temperature",
              kind: :METRIC_KIND_GAUGE,
              unit: "Cel",
              tags: entries(%{"source_zone" => "rack-a", "sensor" => "metric-default"}),
              metadata: entries(%{"calibration" => "metric-default", "kind" => "producer-kind"}),
              points: [
                %MetricPoint{
                  value: 61.5,
                  raw_value: "61.5",
                  raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
                  observed_at_unix_nano: @point_time,
                  attributes: entries(%{"sensor" => "cpu0"}),
                  metadata: entries(%{"calibration" => "point-a"}),
                  series_identity_hint: "sensor:cpu0"
                },
                %MetricPoint{
                  value: 63.0,
                  raw_value: "63.0",
                  raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
                  observed_at_unix_nano: @point_time + 60_000_000_000,
                  attributes: entries(%{"sensor" => "cpu1"}),
                  metadata: entries(%{"calibration" => "point-b"}),
                  series_identity_hint: "sensor:cpu1"
                }
              ]
            }
          ]),
        metadata: %{subject: "metrics.timeseries.environment.temperature"}
      })

    # series_key is derived from attested fields (the distinct point `sensor`
    # attribute), NOT the producer-supplied series_identity_hint. The two points
    # carry distinct attested `sensor` tags so they remain distinct series.
    [key0, key1] = Enum.map(rows, & &1.series_key)
    assert is_binary(key0) and is_binary(key1)
    assert key0 != key1
    refute key0 in ["sensor:cpu0", "sensor:cpu1"]
    assert Enum.map(rows, & &1.value) == [61.5, 63.0]
    assert Enum.map(rows, & &1.tags["sensor"]) == ["cpu0", "cpu1"]
    assert Enum.map(rows, & &1.metadata["calibration"]) == ["point-a", "point-b"]
    assert Enum.map(rows, & &1.metadata["kind"]) == ["producer-kind", "producer-kind"]
    assert Enum.all?(rows, &(&1.tags["source_zone"] == "rack-a"))
  end

  test "counted protobuf metric decode reports row count without changing rows" do
    payload =
      metric_batch([
        %Metric{
          name: "custom.temperature_celsius",
          metric_type: "environment.temperature",
          kind: :METRIC_KIND_GAUGE,
          unit: "Cel",
          points: [
            %MetricPoint{
              value: 61.5,
              observed_at_unix_nano: @point_time,
              series_identity_hint: "sensor:cpu0"
            },
            %MetricPoint{
              value: 63.0,
              observed_at_unix_nano: @point_time + 60_000_000_000,
              series_identity_hint: "sensor:cpu1"
            }
          ]
        }
      ])

    assert {:ok, counted_rows, 2} = MetricEnvelope.decode_rows_count(payload)
    assert {:ok, rows} = MetricEnvelope.decode_rows(payload)
    # Both points share the same attested identity (no distinguishing attribute;
    # only the now-untrusted series_identity_hint differed), so they correctly
    # derive the SAME attested series_key — two samples of one series, not two.
    assert Enum.all?(counted_rows, &(is_binary(&1.series_key) and &1.series_key != ""))

    assert Enum.map(counted_rows, &Map.delete(&1, :created_at)) ==
             Enum.map(rows, &Map.delete(&1, :created_at))
  end

  test "rejects JSON metric bodies after protobuf hard cutover" do
    assert Metrics.parse_message(%{
             data: Jason.encode!(%{"schema" => "serviceradar.metric.v1", "value" => 1.0}),
             metadata: %{subject: "metrics.timeseries.cpu"}
           }) == nil
  end

  test "offline shadow parity preserves canonical JSON and protobuf metric semantics" do
    metrics = [
      gauge_metric("memory.used_percent", "sysmon.memory", 50.0, "%",
        tags: %{"host_id" => "host-1"},
        metadata: %{"used_bytes" => "50", "total_bytes" => "100"},
        series_identity_hint: "sysmon:memory:host-1"
      ),
      %Metric{
        name: "ifHCInOctets",
        metric_type: "snmp",
        kind: :METRIC_KIND_SUM,
        temporality: :METRIC_TEMPORALITY_CUMULATIVE,
        is_monotonic: true,
        unit: "By",
        counter_width: 64,
        tags: entries(%{"target" => "router-a", "host" => "10.0.0.20"}),
        metadata: entries(%{"oid" => ".1.3.6.1.2.1.31.1.1.1.6.7"}),
        points: [
          %MetricPoint{
            value: 1234.5,
            raw_value: "1234",
            raw_value_type: :METRIC_VALUE_TYPE_UINT64,
            observed_at_unix_nano: @point_time,
            if_index: 7,
            interface_uid: "ifindex:7",
            series_identity_hint: "snmp:router-a:ifHCInOctets:7",
            attributes: entries(%{"target" => "router-a", "host" => "10.0.0.20"})
          }
        ]
      }
    ]

    protobuf_payload = metric_batch(metrics)
    legacy_payload = legacy_metric_json(metrics)

    protobuf_rows =
      Metrics.parse_message(%{data: protobuf_payload, metadata: %{subject: "metrics.shadow"}})

    legacy_rows = legacy_json_metric_rows(legacy_payload)

    assert Enum.map(protobuf_rows, &canonical_row/1) ==
             Enum.map(legacy_rows, &canonical_row/1)
  end

  test "parse_message/1 no longer emits per-message success telemetry" do
    attach_decode_handler(self())

    assert [_row] =
             Metrics.parse_message(%{
               data:
                 metric_batch([
                   gauge_metric("memory.used_percent", "sysmon.memory", 50.0, "%", [])
                 ]),
               metadata: %{subject: "metrics.sysmon.memory", source: "sysmon-metrics"}
             })

    # Success telemetry moved to the per-batch path (decode_batch/1); a single
    # decoded message must not fire decode/completed or schema_version anymore.
    refute_receive {:telemetry, @decode_completed, _measurements, _metadata}
    refute_receive {:telemetry, @schema_version, _measurements, _metadata}
  end

  test "decode_batch/1 emits ONE aggregated decode telemetry event per batch" do
    attach_decode_handler(self())

    message = fn ->
      %{
        data:
          metric_batch([
            gauge_metric("memory.used_percent", "sysmon.memory", 50.0, "%", [])
          ]),
        metadata: %{subject: "metrics.sysmon.memory", source: "sysmon-metrics"}
      }
    end

    # Three messages of one row each in a single batch.
    {rows, 0} = Metrics.decode_batch([message.(), message.(), message.()])
    assert length(rows) == 3

    # Exactly one aggregated decode/completed: count summed across the batch,
    # rows summed, duration summed (>= 0).
    assert_receive {:telemetry, @decode_completed, %{count: 3, rows: 3, duration: duration},
                    metadata}

    assert is_integer(duration)
    assert duration >= 0
    assert metadata.source == "sysmon-metrics"
    assert metadata.schema_version == "serviceradar.metric.v1"

    # Exactly one aggregated schema_version event, count summed.
    assert_receive {:telemetry, @schema_version, %{count: 3}, schema_metadata}
    assert schema_metadata.source == "sysmon-metrics"
    assert schema_metadata.schema_version == "serviceradar.metric.v1"

    # No second copy of either event (per-batch, not per-message).
    refute_receive {:telemetry, @decode_completed, _measurements, _metadata}
    refute_receive {:telemetry, @schema_version, _measurements, _metadata}
  end

  test "emits decode failure telemetry for invalid metric envelopes" do
    attach_decode_handler(self())

    assert Metrics.parse_message(%{
             data: <<"not protobuf">>,
             metadata: %{subject: "metrics.timeseries.cpu", source: "plugin-metrics"}
           }) == nil

    assert_receive {:telemetry, @decode_failed, %{count: 1, duration: duration}, metadata}
    assert is_integer(duration)
    assert duration >= 0
    assert metadata.source == "plugin-metrics"
    assert is_atom(metadata.reason)
  end

  defp metric_batch(metrics) do
    MetricBatch.encode(%MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{
        agent_id: "agent-1",
        gateway_id: "gateway-1",
        partition: "default",
        service_name: "metrics",
        service_type: "metrics"
      },
      ingest_identity: %IngestIdentity{
        source: "sysmon-metrics",
        payload_kind: "serviceradar.metric.v1",
        producer_id: "agent-1",
        producer_kind: "agent"
      },
      emitted_at_unix_nano: @point_time,
      metrics: metrics
    })
  end

  defp gauge_metric(name, metric_type, value, unit, opts) do
    %Metric{
      name: name,
      metric_type: metric_type,
      kind: :METRIC_KIND_GAUGE,
      unit: unit,
      tags: opts |> Keyword.get(:tags, %{}) |> entries(),
      metadata: opts |> Keyword.get(:metadata, %{}) |> entries(),
      points: [
        %MetricPoint{
          value: value,
          raw_value: Float.to_string(value),
          raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
          observed_at_unix_nano: @point_time,
          series_identity_hint: Keyword.get(opts, :series_identity_hint, "")
        }
      ]
    }
  end

  defp legacy_metric_json(metrics) do
    Jason.encode!(%{
      "schema_version" => "serviceradar.metric.v1",
      "resource" => %{
        "agent_id" => "agent-1",
        "gateway_id" => "gateway-1",
        "partition" => "default",
        "service_name" => "metrics",
        "service_type" => "metrics"
      },
      "ingest_identity" => %{
        "source" => "sysmon-metrics",
        "payload_kind" => "serviceradar.metric.v1",
        "producer_id" => "agent-1",
        "producer_kind" => "agent"
      },
      "emitted_at_unix_nano" => @point_time,
      "metrics" => Enum.map(metrics, &legacy_metric/1)
    })
  end

  defp legacy_metric(%Metric{} = metric) do
    %{
      "name" => metric.name,
      "metric_type" => metric.metric_type,
      "kind" => legacy_kind(metric.kind),
      "temporality" => legacy_temporality(metric.temporality),
      "is_monotonic" => metric.is_monotonic,
      "unit" => metric.unit,
      "scale" => metric.scale,
      "counter_width" => metric.counter_width,
      "tags" => legacy_entries(metric.tags),
      "metadata" => legacy_entries(metric.metadata),
      "points" => Enum.map(metric.points, &legacy_point/1)
    }
  end

  defp legacy_point(%MetricPoint{} = point) do
    %{
      "value" => point.value,
      "raw_value" => point.raw_value,
      "raw_value_type" => legacy_raw_value_type(point.raw_value_type),
      "observed_at_unix_nano" => point.observed_at_unix_nano,
      "start_time_unix_nano" => point.start_time_unix_nano,
      "reset_anchor" => point.reset_anchor,
      "if_index" => point.if_index,
      "interface_uid" => point.interface_uid,
      "series_identity_hint" => point.series_identity_hint,
      "attributes" => legacy_entries(point.attributes),
      "metadata" => legacy_entries(point.metadata)
    }
  end

  defp legacy_json_metric_rows(payload) do
    decoded = Jason.decode!(payload)
    resource = decoded["resource"] || %{}
    ingest_identity = decoded["ingest_identity"] || %{}

    Enum.flat_map(decoded["metrics"] || [], fn metric ->
      Enum.map(metric["points"] || [], fn point ->
        tags =
          (metric["tags"] || %{})
          |> Map.merge(point["attributes"] || %{})
          |> maybe_put("source", ingest_identity["source"])
          |> maybe_put("payload_kind", ingest_identity["payload_kind"])
          |> maybe_put("producer_id", ingest_identity["producer_id"])
          |> maybe_put("producer_kind", ingest_identity["producer_kind"])
          |> maybe_put("interface_uid", point["interface_uid"])

        metadata =
          (metric["metadata"] || %{})
          |> Map.merge(point["metadata"] || %{})
          |> maybe_put("schema", decoded["schema_version"])
          |> maybe_put("kind", metric["kind"])
          |> maybe_put("temporality", metric["temporality"])
          |> maybe_put("is_monotonic", metric["is_monotonic"])
          |> maybe_put("raw_value", point["raw_value"])
          |> maybe_put("raw_value_type", point["raw_value_type"])
          |> maybe_put("counter_width", metric["counter_width"])
          |> maybe_put("start_time_unix_nano", point["start_time_unix_nano"])
          |> maybe_put("reset_anchor", point["reset_anchor"])
          |> maybe_put("ingress_id", decoded["ingress_id"])
          |> maybe_put("ingress_timestamp_unix_nano", decoded["ingress_timestamp_unix_nano"])

        base = %{
          timestamp: DateTime.from_unix!(point["observed_at_unix_nano"], :nanosecond),
          gateway_id: resource["gateway_id"] || "unknown",
          agent_id: resource["agent_id"],
          metric_name: metric["name"] || "unknown",
          metric_type: metric["metric_type"] || metric["kind"] || "gauge",
          device_id: resource["device_id"],
          value: point["value"],
          unit: metric["unit"],
          tags: tags,
          partition: resource["partition"],
          scale: metric["scale"],
          is_delta: metric["temporality"] == "delta",
          target_device_ip:
            resource["target_device_ip"] || tags["host"] || metadata["target_device_ip"] ||
              tags["target"],
          if_index: positive(point["if_index"]),
          metadata: metadata,
          created_at: DateTime.utc_now()
        }

        Map.put(
          base,
          :series_key,
          TimeseriesSeriesKey.build(base)
        )
      end)
    end)
  end

  defp canonical_row(row) do
    %{
      gateway_id: row.gateway_id,
      agent_id: row.agent_id,
      metric_name: row.metric_name,
      metric_type: row.metric_type,
      series_key: row.series_key,
      value: row.value,
      unit: row.unit,
      partition: row.partition,
      target_device_ip: row.target_device_ip,
      if_index: row.if_index,
      tags: row.tags,
      metadata:
        Map.take(row.metadata, [
          "schema",
          "kind",
          "temporality",
          "is_monotonic",
          "raw_value",
          "raw_value_type",
          "counter_width",
          "oid",
          "used_bytes",
          "total_bytes"
        ])
    }
  end

  defp legacy_entries(entries), do: Map.new(entries, &{&1.key, &1.value})

  defp legacy_kind(:METRIC_KIND_GAUGE), do: "gauge"
  defp legacy_kind(:METRIC_KIND_SUM), do: "sum"
  defp legacy_kind(:METRIC_KIND_HISTOGRAM), do: "histogram"
  defp legacy_kind(_kind), do: nil

  defp legacy_temporality(:METRIC_TEMPORALITY_DELTA), do: "delta"
  defp legacy_temporality(:METRIC_TEMPORALITY_CUMULATIVE), do: "cumulative"
  defp legacy_temporality(_temporality), do: nil

  defp legacy_raw_value_type(:METRIC_VALUE_TYPE_DOUBLE), do: "double"
  defp legacy_raw_value_type(:METRIC_VALUE_TYPE_INT64), do: "int64"
  defp legacy_raw_value_type(:METRIC_VALUE_TYPE_UINT64), do: "uint64"
  defp legacy_raw_value_type(:METRIC_VALUE_TYPE_BOOL), do: "bool"
  defp legacy_raw_value_type(:METRIC_VALUE_TYPE_STRING), do: "string"
  defp legacy_raw_value_type(_type), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, 0), do: map
  defp maybe_put(map, key, value), do: Map.put_new(map, key, value)

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp attach_decode_handler(test_pid) do
    handler_id = "metric-envelope-decode-#{inspect(make_ref())}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [@decode_completed, @decode_failed, @schema_version],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "numeric_row?/1" do
    # A string-typed SNMP reading rides through the envelope carrying value 0.0
    # so the protobuf point has a shape at all. Letting it into
    # timeseries_metrics would create a permanently flat series for a version
    # string and feed that to anomaly detection.
    test "excludes a reading the timeseries column cannot represent" do
      refute Metrics.numeric_row?(%{metadata: %{"non_numeric" => "true", "oid" => ".1.3.6.1.2"}})
    end

    test "keeps an ordinary numeric reading" do
      assert Metrics.numeric_row?(%{metadata: %{"oid" => ".1.3.6.1.2"}})
    end

    # The marker is absent on every metric the rest of the system produces, so
    # its absence must never exclude a row.
    test "keeps a row with no metadata at all" do
      assert Metrics.numeric_row?(%{})
      assert Metrics.numeric_row?(%{metadata: nil})
      assert Metrics.numeric_row?(%{metadata: %{}})
    end
  end

  defp entries(map) do
    Enum.map(map, fn {key, value} -> %StringMapEntry{key: key, value: to_string(value)} end)
  end
end
