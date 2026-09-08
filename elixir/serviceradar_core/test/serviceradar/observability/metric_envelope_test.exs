defmodule ServiceRadar.Observability.MetricEnvelopeTest do
  use ExUnit.Case, async: true

  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.Observability.MetricEnvelope
  alias ServiceRadar.Observability.TimeseriesSeriesKey

  @point_time 1_781_222_400_000_000_000

  describe "target_device_ip resolution (finding 1)" do
    test "SNMP envelope resolves target_device_ip to the IP-bearing host tag, not the target name" do
      # Producer convention: tags["host"] = polled IP, tags["target"] = logical
      # name. The IP must win so downstream identity/series keys use the IP.
      [row] =
        decode_one(snmp_metric(tags: %{"target" => "router-a", "host" => "10.0.0.20"}))

      assert row.target_device_ip == "10.0.0.20"
    end

    test "falls back to the logical target name only when no IP-bearing key is present" do
      [row] = decode_one(snmp_metric(tags: %{"target" => "router-a"}))

      assert row.target_device_ip == "router-a"
    end

    test "uses resource host_ip for sysmon device-id backfill" do
      payload =
        encode_batch([gauge_metric("cpu.usage_percent", "sysmon.cpu", 12.5, [])],
          host_ip: "10.0.2.13"
        )

      resolver = fn ips ->
        assert ips == ["10.0.2.13"]
        %{"10.0.2.13" => "sr:k8s-cp3-worker3"}
      end

      {:ok, [row], 1} =
        MetricEnvelope.decode_rows_count(payload, device_resolver: resolver)

      assert row.target_device_ip == "10.0.2.13"
      assert row.device_id == "sr:k8s-cp3-worker3"
    end
  end

  describe "counter_width threading (SNMP counter wrap)" do
    test "persists the SNMP counter bit-width as a first-class row field" do
      [row] = decode_one(snmp_metric(tags: %{"host" => "10.0.0.20"}))

      # The width drives the SRQL rate query's wrap modulus (2^32 vs 2^64); it must be a
      # top-level column, not only buried in metadata, so the rate CTE can branch on it.
      assert row.counter_width == 64
      assert row.metadata["counter_width"] == 64
    end

    test "leaves counter_width nil when the width is unknown (gauge / width 0)" do
      [row] = decode_one(gauge_metric("memory.used_percent", "sysmon.memory", 42.0, []))

      assert row.counter_width == nil
    end
  end

  describe "series_key trust boundary (finding 2a)" do
    test "emits telemetry for mismatched producer hints without trusting them" do
      event = [:serviceradar, :observability, :series_identity_hint, :mismatch]
      handler_id = {:metric_envelope_series_hint_mismatch, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, metadata, _config ->
          send(test_pid, {handler_id, measurements, metadata})
        end,
        nil
      )

      try do
        [row] =
          decode_one(
            gauge_metric("memory.used_percent", "sysmon.memory", 50.0,
              tags: %{"host_id" => "host-1"},
              series_identity_hint: "spoofed-key"
            )
          )

        assert row.metadata["series_identity_hint"] == "spoofed-key"
        assert_receive {^handler_id, %{count: 1}, %{source: :metric_envelope}}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "derives series_key from attested fields even when a different hint is present" do
      [row] =
        decode_one(
          gauge_metric("memory.used_percent", "sysmon.memory", 50.0,
            tags: %{"host_id" => "host-1"},
            series_identity_hint: "spoofed-key"
          )
        )

      # The canonical key is the attested-field derivation, NOT the hint.
      assert row.series_key == TimeseriesSeriesKey.build(Map.delete(row, :series_key))
      refute row.series_key == "spoofed-key"
    end

    test "keeps the hint only as debug metadata, never as the canonical key" do
      [row] =
        decode_one(
          gauge_metric("memory.used_percent", "sysmon.memory", 50.0,
            tags: %{"host_id" => "host-1"},
            series_identity_hint: "sysmon:memory:host-1"
          )
        )

      assert row.metadata["series_identity_hint"] == "sysmon:memory:host-1"
      assert row.series_key != "sysmon:memory:host-1"
    end

    test "omits the hint metadata key entirely when no hint is supplied" do
      [row] =
        decode_one(
          gauge_metric("memory.used_percent", "sysmon.memory", 50.0,
            tags: %{"host_id" => "host-1"}
          )
        )

      refute Map.has_key?(row.metadata, "series_identity_hint")
    end
  end

  describe "series_key cardinality guards" do
    test "does not split sysmon percentage series on sampled byte counters" do
      [first] =
        decode_one(
          gauge_metric("memory.used_percent", "sysmon.memory", 50.0,
            tags: %{"used_bytes" => "500", "total_bytes" => "1000"}
          )
        )

      [second] =
        decode_one(
          gauge_metric("memory.used_percent", "sysmon.memory", 60.0,
            tags: %{"used_bytes" => "600", "total_bytes" => "1000"}
          )
        )

      assert first.series_key == second.series_key
    end

    test "does not split sweep host series on execution identifiers" do
      first =
        TimeseriesSeriesKey.build(%{
          metric_type: "sweep",
          metric_name: "sweep.host.available",
          partition: "default",
          agent_id: "agent-1",
          target_device_ip: "10.0.0.10",
          tags: %{
            "target" => "10.0.0.10",
            "network" => "edge-lan",
            "execution_id" => "exec-1",
            "sweep_group_id" => "group-1",
            "source" => "sweep-metrics",
            "payload_kind" => "serviceradar.metric.v1",
            "producer_id" => "agent-1",
            "producer_kind" => "agent-sweep"
          }
        })

      second =
        TimeseriesSeriesKey.build(%{
          metric_type: "sweep",
          metric_name: "sweep.host.available",
          partition: "default",
          agent_id: "agent-1",
          target_device_ip: "10.0.0.10",
          tags: %{
            "target" => "10.0.0.10",
            "network" => "edge-lan",
            "execution_id" => "exec-2",
            "sweep_group_id" => "group-2",
            "source" => "sweep-metrics",
            "payload_kind" => "serviceradar.metric.v1",
            "producer_id" => "agent-1",
            "producer_kind" => "agent-sweep"
          }
        })

      assert first == second
    end

    test "keeps real dimensions in the series key" do
      root =
        TimeseriesSeriesKey.build(%{
          metric_type: "sysmon.disk",
          metric_name: "disk.used_percent",
          partition: "default",
          agent_id: "agent-1",
          tags: %{"mount_point" => "/", "used_bytes" => "500", "total_bytes" => "1000"}
        })

      var =
        TimeseriesSeriesKey.build(%{
          metric_type: "sysmon.disk",
          metric_name: "disk.used_percent",
          partition: "default",
          agent_id: "agent-1",
          tags: %{"mount_point" => "/var", "used_bytes" => "500", "total_bytes" => "1000"}
        })

      assert root != var
    end

    test "does not split process series on volatile status changes" do
      running =
        TimeseriesSeriesKey.build(%{
          metric_type: "sysmon.process",
          metric_name: "process.cpu_usage",
          partition: "default",
          agent_id: "agent-1",
          tags: %{
            "pid" => "1234",
            "name" => "nginx",
            "start_time" => "2026-06-22T12:00:00Z",
            "status" => "Running"
          }
        })

      sleeping =
        TimeseriesSeriesKey.build(%{
          metric_type: "sysmon.process",
          metric_name: "process.cpu_usage",
          partition: "default",
          agent_id: "agent-1",
          tags: %{
            "pid" => "1234",
            "name" => "nginx",
            "start_time" => "2026-06-22T12:00:00Z",
            "status" => "Sleeping"
          }
        })

      assert running == sleeping
    end
  end

  describe "device_id resolution on the row-build path (finding 4)" do
    test "is lookup-free by default and leaves device_id from the attested resource" do
      [row] = decode_one(snmp_metric(tags: %{"host" => "10.0.0.20"}))

      # No resolver supplied: device_id is whatever the gateway attested (nil here).
      assert row.device_id == nil
    end

    test "backfills device_id from the batched resolver keyed on target_device_ip" do
      payload = encode_batch([snmp_metric(tags: %{"host" => "10.0.0.20"})])

      resolver = fn ips ->
        assert ips == ["10.0.0.20"]
        %{"10.0.0.20" => "device-canonical-1"}
      end

      {:ok, [row], 1} =
        MetricEnvelope.decode_rows_count(payload, device_resolver: resolver)

      assert row.device_id == "device-canonical-1"
    end

    test "does not override an already-attested device_id" do
      payload =
        encode_batch([snmp_metric(tags: %{"host" => "10.0.0.20"})],
          device_id: "attested-device"
        )

      resolver = fn _ips -> %{"10.0.0.20" => "resolver-device"} end

      {:ok, [row], 1} =
        MetricEnvelope.decode_rows_count(payload, device_resolver: resolver)

      assert row.device_id == "attested-device"
    end
  end

  defp decode_one(metric) do
    {:ok, rows} = MetricEnvelope.decode_rows(encode_batch([metric]))
    rows
  end

  defp encode_batch(metrics, opts \\ []) do
    MetricBatch.encode(%MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{
        agent_id: "agent-1",
        gateway_id: "gateway-1",
        partition: "default",
        device_id: Keyword.get(opts, :device_id, ""),
        host_ip: Keyword.get(opts, :host_ip, ""),
        service_name: "metrics",
        service_type: "metrics"
      },
      ingest_identity: %IngestIdentity{
        source: "metrics",
        payload_kind: "serviceradar.metric.v1",
        producer_id: "agent-1",
        producer_kind: "agent"
      },
      emitted_at_unix_nano: @point_time,
      metrics: metrics
    })
  end

  defp snmp_metric(opts) do
    %Metric{
      name: "ifHCInOctets",
      metric_type: "snmp",
      kind: :METRIC_KIND_SUM,
      temporality: :METRIC_TEMPORALITY_CUMULATIVE,
      is_monotonic: true,
      unit: "By",
      counter_width: 64,
      tags: opts |> Keyword.get(:tags, %{}) |> entries(),
      points: [
        %MetricPoint{
          value: 1234.5,
          raw_value: "1234",
          raw_value_type: :METRIC_VALUE_TYPE_UINT64,
          observed_at_unix_nano: @point_time,
          if_index: 7
        }
      ]
    }
  end

  defp gauge_metric(name, metric_type, value, opts) do
    %Metric{
      name: name,
      metric_type: metric_type,
      kind: :METRIC_KIND_GAUGE,
      unit: "%",
      tags: opts |> Keyword.get(:tags, %{}) |> entries(),
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

  defp entries(map) do
    Enum.map(map, fn {key, value} -> %StringMapEntry{key: key, value: to_string(value)} end)
  end
end
