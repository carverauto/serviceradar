defmodule ServiceRadar.Observability.SnmpMetricsIngestorIntegrationTest do
  @moduledoc """
  Integration coverage for SNMP metrics ingestion through ResultsRouter.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.TimeseriesMetric
  alias ServiceRadar.Repo
  alias ServiceRadar.ResultsRouter
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    ensure_timeseries_series_identity!()
    :ok
  end

  test "snmp metrics flow through ResultsRouter" do
    actor = SystemActor.system(:test)
    agent_id = "test-agent-#{System.unique_integer([:positive])}"
    timestamp = DateTime.to_iso8601(DateTime.utc_now())

    payload = %{
      "results" => [
        %{
          "timestamp" => timestamp,
          "metric" => "ifInOctets",
          "value" => 123.0,
          "target" => "192.0.2.10",
          "interface_uid" => "ifindex:3",
          "oid" => ".1.3.6.1.2.1.31.1.1.1.6.3",
          "scale" => 1.0,
          "delta" => true
        }
      ]
    }

    status = %{
      source: "snmp-metrics",
      service_type: "snmp",
      service_name: "snmp",
      message: Jason.encode!(payload),
      agent_id: agent_id,
      gateway_id: "test-gateway",
      partition: "default",
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    query =
      Ash.Query.filter(
        TimeseriesMetric,
        agent_id == ^agent_id and metric_type == "snmp" and metric_name == "ifInOctets"
      )

    assert {:ok, metrics} = Ash.read(query, actor: actor)
    assert Enum.any?(metrics)
  end

  test "snmp metrics normalize interface uid and metric name" do
    actor = SystemActor.system(:test)
    agent_id = "test-agent-#{System.unique_integer([:positive])}"
    timestamp = DateTime.to_iso8601(DateTime.utc_now())

    payload = %{
      "results" => [
        %{
          "timestamp" => timestamp,
          "metric" => "ifInErrors::ifindex:3",
          "value" => 0,
          "target" => "192.0.2.11",
          "interface_uid" => "ifindex:3"
        }
      ]
    }

    status = %{
      source: "snmp-metrics",
      service_type: "snmp",
      service_name: "snmp",
      message: Jason.encode!(payload),
      agent_id: agent_id,
      gateway_id: "test-gateway",
      partition: "default",
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    query = Ash.Query.filter(TimeseriesMetric, metric_name == "ifInErrors" and if_index == 3)

    assert {:ok, metrics} = Ash.read(query, actor: actor)
    assert Enum.any?(metrics)
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
