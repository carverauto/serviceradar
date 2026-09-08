defmodule ServiceRadar.Observability.TimeseriesSeriesIdentityIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.Observability.TimeseriesMetric
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    ensure_timeseries_series_identity!()
    :ok
  end

  test "protobuf snmp metric envelope preserves distinct interface series and dedupes exact duplicates" do
    actor = SystemActor.system(:test)
    agent_id = "snmp-series-agent-#{System.unique_integer([:positive])}"
    gateway_id = "snmp-series-gateway-#{System.unique_integer([:positive])}"

    observed_at =
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_unix(:nanosecond)

    payload =
      MetricBatch.encode(%MetricBatch{
        schema_version: "serviceradar.metric.v1",
        resource: %MetricResource{
          agent_id: agent_id,
          gateway_id: gateway_id,
          partition: "default",
          service_name: "snmp",
          service_type: "snmp"
        },
        ingest_identity: %IngestIdentity{
          source: "snmp-metrics",
          payload_kind: "serviceradar.metric.v1",
          producer_id: agent_id,
          producer_kind: "agent"
        },
        metrics: [
          %Metric{
            name: "ifInOctets",
            metric_type: "snmp",
            kind: :METRIC_KIND_SUM,
            temporality: :METRIC_TEMPORALITY_CUMULATIVE,
            is_monotonic: true,
            counter_width: 64,
            points: [
              snmp_point(123.0, observed_at, 3),
              snmp_point(123.0, observed_at, 3),
              snmp_point(456.0, observed_at, 4)
            ],
            tags: entries(%{"target" => "192.0.2.20"}),
            metadata: entries(%{"oid" => ".1.3.6.1.2.1.31.1.1.1.6"})
          }
        ]
      })

    batch = [%{data: payload, metadata: %{subject: "metrics.snmp.snmp.ifInOctets"}}]

    assert {:ok, 2} = Metrics.process_batch(batch)
    assert {:ok, 0} = Metrics.process_batch(batch)

    metrics = fetch_metrics(actor, agent_id, gateway_id, "snmp", "ifInOctets")

    assert length(metrics) == 2
    assert MapSet.new(Enum.map(metrics, & &1.if_index)) == MapSet.new([3, 4])
    assert MapSet.size(MapSet.new(Enum.map(metrics, & &1.series_key))) == 2
  end

  test "protobuf icmp metric envelope preserves distinct check series at the same timestamp" do
    actor = SystemActor.system(:test)
    agent_id = "icmp-series-agent-#{System.unique_integer([:positive])}"
    gateway_id = "icmp-series-gateway-#{System.unique_integer([:positive])}"

    observed_at =
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_unix(:nanosecond)

    payload =
      MetricBatch.encode(%MetricBatch{
        schema_version: "serviceradar.metric.v1",
        resource: %MetricResource{
          agent_id: agent_id,
          gateway_id: gateway_id,
          partition: "default",
          service_name: "icmp_checks",
          service_type: "icmp"
        },
        ingest_identity: %IngestIdentity{
          source: "icmp-metrics",
          payload_kind: "serviceradar.metric.v1",
          producer_id: agent_id,
          producer_kind: "agent"
        },
        metrics: [
          %Metric{
            name: "icmp_response_time_ns",
            metric_type: "icmp",
            kind: :METRIC_KIND_GAUGE,
            unit: "ns",
            points: [
              icmp_point(1_000_000, observed_at, "icmp-check-a"),
              icmp_point(2_000_000, observed_at, "icmp-check-b")
            ]
          }
        ]
      })

    assert {:ok, 2} =
             Metrics.process_batch([
               %{
                 data: payload,
                 metadata: %{subject: "metrics.icmp.icmp.icmp_response_time_ns"}
               }
             ])

    metrics = fetch_metrics(actor, agent_id, gateway_id, "icmp", "icmp_response_time_ns")

    assert length(metrics) == 2
    assert MapSet.size(MapSet.new(Enum.map(metrics, & &1.series_key))) == 2
  end

  test "protobuf plugin metric envelope preserves label-distinguished series at the same timestamp" do
    actor = SystemActor.system(:test)
    agent_id = "plugin-series-agent-#{System.unique_integer([:positive])}"
    gateway_id = "plugin-series-gateway-#{System.unique_integer([:positive])}"

    observed_at =
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_unix(:nanosecond)

    payload =
      MetricBatch.encode(%MetricBatch{
        schema_version: "serviceradar.metric.v1",
        resource: %MetricResource{
          agent_id: agent_id,
          gateway_id: gateway_id,
          partition: "default",
          service_name: "plugin-temp",
          service_type: "plugin"
        },
        ingest_identity: %IngestIdentity{
          source: "native-addon",
          payload_kind: "serviceradar.metric.v1",
          producer_id: "plugin-temp",
          producer_kind: "plugin"
        },
        metrics: [
          %Metric{
            name: "temp_c",
            metric_type: "plugin",
            kind: :METRIC_KIND_GAUGE,
            points: [
              %MetricPoint{
                value: 40.0,
                raw_value: "40.0",
                raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
                observed_at_unix_nano: observed_at,
                attributes: entries(%{"instance" => "a", "plugin" => "temp"})
              },
              %MetricPoint{
                value: 41.0,
                raw_value: "41.0",
                raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
                observed_at_unix_nano: observed_at,
                attributes: entries(%{"instance" => "b", "plugin" => "temp"})
              }
            ]
          }
        ]
      })

    assert {:ok, 2} =
             Metrics.process_batch([
               %{
                 data: payload,
                 metadata: %{subject: "metrics.timeseries.plugin.temp_c"}
               }
             ])

    metrics = fetch_metrics(actor, agent_id, gateway_id, "plugin", "temp_c")

    assert length(metrics) == 2
    assert MapSet.size(MapSet.new(Enum.map(metrics, & &1.series_key))) == 2
  end

  defp entries(values) do
    Enum.map(values, fn {key, value} -> %StringMapEntry{key: key, value: value} end)
  end

  defp snmp_point(value, observed_at, if_index) do
    %MetricPoint{
      value: value,
      raw_value: to_string(trunc(value)),
      raw_value_type: :METRIC_VALUE_TYPE_UINT64,
      observed_at_unix_nano: observed_at,
      if_index: if_index,
      interface_uid: "ifindex:#{if_index}",
      attributes:
        entries(%{
          "target" => "192.0.2.20",
          "interface_uid" => "ifindex:#{if_index}",
          "oid" => ".1.3.6.1.2.1.31.1.1.1.6.#{if_index}"
        })
    }
  end

  defp icmp_point(value, observed_at, check_id) do
    %MetricPoint{
      value: value,
      raw_value: Integer.to_string(value),
      raw_value_type: :METRIC_VALUE_TYPE_INT64,
      observed_at_unix_nano: observed_at,
      attributes:
        entries(%{
          "target" => "192.0.2.30",
          "check_id" => check_id
        })
    }
  end

  defp fetch_metrics(actor, agent_id, gateway_id, metric_type, metric_name) do
    TimeseriesMetric
    |> Ash.Query.filter(
      agent_id == ^agent_id and gateway_id == ^gateway_id and metric_type == ^metric_type and
        metric_name == ^metric_name
    )
    |> Ash.read!(actor: actor)
  end

  defp ensure_timeseries_series_identity! do
    Repo.query!(
      "ALTER TABLE platform.timeseries_metrics ADD COLUMN IF NOT EXISTS series_key TEXT"
    )

    Repo.query!("""
    UPDATE platform.timeseries_metrics
    SET series_key = md5(
      coalesce(metric_type, '') || '|' ||
      coalesce(metric_name, '') || '|' ||
      coalesce(partition, '') || '|' ||
      coalesce(agent_id, '') || '|' ||
      coalesce(device_id, '') || '|' ||
      coalesce(target_device_ip, '') || '|' ||
      coalesce(if_index::text, '') || '|' ||
      coalesce((
        SELECT string_agg(entry.key || '=' || entry.value, '|' ORDER BY entry.key)
        FROM jsonb_each_text(coalesce(tags, '{}'::jsonb)) AS entry(key, value)
        WHERE entry.key NOT IN ('available', 'metric', 'packet_loss')
      ), '')
    )
    WHERE series_key IS NULL
    """)

    Repo.query!("ALTER TABLE platform.timeseries_metrics ALTER COLUMN series_key SET NOT NULL")

    Repo.query!("""
    DO $$
    DECLARE
      current_def text;
    BEGIN
      SELECT pg_get_constraintdef(oid)
      INTO current_def
      FROM pg_constraint
      WHERE conrelid = 'platform.timeseries_metrics'::regclass
        AND conname = 'timeseries_metrics_pkey';

      IF current_def IS NULL OR current_def NOT LIKE '%series_key%' THEN
        ALTER TABLE platform.timeseries_metrics DROP CONSTRAINT IF EXISTS timeseries_metrics_pkey;
        ALTER TABLE platform.timeseries_metrics
          ADD CONSTRAINT timeseries_metrics_pkey PRIMARY KEY (timestamp, gateway_id, series_key);
      END IF;
    END
    $$;
    """)
  end
end
