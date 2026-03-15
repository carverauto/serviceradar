defmodule ServiceRadar.Observability.TimeseriesSeriesIdentityIntegrationTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.IcmpMetricsIngestor
  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Observability.SnmpMetricsIngestor
  alias ServiceRadar.Observability.TimeseriesMetric
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    ensure_timeseries_series_identity!()
    :ok
  end

  test "snmp ingest preserves distinct interface series and dedupes exact duplicates" do
    actor = SystemActor.system(:test)
    agent_id = "snmp-series-agent-#{System.unique_integer([:positive])}"
    gateway_id = "snmp-series-gateway-#{System.unique_integer([:positive])}"
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    payload = %{
      "results" => [
        %{
          "timestamp" => timestamp,
          "metric" => "ifInOctets",
          "value" => 123.0,
          "target" => "192.0.2.20",
          "interface_uid" => "ifindex:3",
          "oid" => ".1.3.6.1.2.1.31.1.1.1.6.3"
        },
        %{
          "timestamp" => timestamp,
          "metric" => "ifInOctets",
          "value" => 123.0,
          "target" => "192.0.2.20",
          "interface_uid" => "ifindex:3",
          "oid" => ".1.3.6.1.2.1.31.1.1.1.6.3"
        },
        %{
          "timestamp" => timestamp,
          "metric" => "ifInOctets",
          "value" => 456.0,
          "target" => "192.0.2.20",
          "interface_uid" => "ifindex:4",
          "oid" => ".1.3.6.1.2.1.31.1.1.1.6.4"
        }
      ]
    }

    status = %{
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: "default",
      timestamp: DateTime.utc_now()
    }

    assert :ok = SnmpMetricsIngestor.ingest(payload, status)
    assert :ok = SnmpMetricsIngestor.ingest(payload, status)

    metrics = fetch_metrics(actor, agent_id, gateway_id, "snmp", "ifInOctets")

    assert length(metrics) == 2
    assert MapSet.new(Enum.map(metrics, & &1.if_index)) == MapSet.new([3, 4])
    assert MapSet.size(MapSet.new(Enum.map(metrics, & &1.series_key))) == 2
  end

  test "icmp ingest preserves distinct check series at the same timestamp" do
    actor = SystemActor.system(:test)
    agent_id = "icmp-series-agent-#{System.unique_integer([:positive])}"
    gateway_id = "icmp-series-gateway-#{System.unique_integer([:positive])}"
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    payload = %{
      "results" => [
        %{
          "timestamp" => timestamp,
          "target" => "192.0.2.30",
          "response_time_ns" => 1_000_000,
          "check_id" => "icmp-check-a"
        },
        %{
          "timestamp" => timestamp,
          "target" => "192.0.2.30",
          "response_time_ns" => 2_000_000,
          "check_id" => "icmp-check-b"
        }
      ]
    }

    status = %{
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: "default",
      timestamp: DateTime.utc_now()
    }

    assert :ok = IcmpMetricsIngestor.ingest(payload, status)

    metrics = fetch_metrics(actor, agent_id, gateway_id, "icmp", "icmp_response_time_ns")

    assert length(metrics) == 2
    assert MapSet.size(MapSet.new(Enum.map(metrics, & &1.series_key))) == 2
  end

  test "plugin ingest preserves label-distinguished series at the same timestamp" do
    actor = SystemActor.system(:test)
    agent_id = "plugin-series-agent-#{System.unique_integer([:positive])}"
    gateway_id = "plugin-series-gateway-#{System.unique_integer([:positive])}"
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    payload_a = %{
      "observed_at" => observed_at,
      "status" => "ok",
      "labels" => %{"instance" => "a", "plugin" => "temp"},
      "metrics" => [%{"name" => "temp_c", "value" => 40.0}]
    }

    payload_b = %{
      "observed_at" => observed_at,
      "status" => "ok",
      "labels" => %{"instance" => "b", "plugin" => "temp"},
      "metrics" => [%{"name" => "temp_c", "value" => 41.0}]
    }

    status_a = %{
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: "default",
      service_name: "plugin-temp-a",
      service_type: "plugin",
      timestamp: DateTime.utc_now()
    }

    status_b = %{
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: "default",
      service_name: "plugin-temp-b",
      service_type: "plugin",
      timestamp: DateTime.utc_now()
    }

    assert :ok = PluginResultIngestor.ingest(payload_a, status_a)
    assert :ok = PluginResultIngestor.ingest(payload_b, status_b)

    metrics = fetch_metrics(actor, agent_id, gateway_id, "plugin", "temp_c")

    assert length(metrics) == 2
    assert MapSet.size(MapSet.new(Enum.map(metrics, & &1.series_key))) == 2
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
