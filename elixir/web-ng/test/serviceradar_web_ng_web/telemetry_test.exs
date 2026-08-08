defmodule ServiceRadarWebNGWeb.TelemetryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Telemetry

  @moduletag :db_free

  test "includes camera relay metrics in the Prometheus reporter set" do
    metric_names = Enum.map(Telemetry.metrics(), & &1.name)

    assert [:serviceradar, :camera_relay, :session, :opened, :count] in metric_names
    assert [:serviceradar, :camera_relay, :session, :closing, :count] in metric_names
    assert [:serviceradar, :camera_relay, :session, :closed, :count] in metric_names
    assert [:serviceradar, :camera_relay, :session, :failed, :count] in metric_names
    assert [:serviceradar, :camera_relay, :session, :viewer_count] in metric_names
  end

  test "includes hosted runtime contract metrics in the Prometheus reporter set" do
    metric_names = Enum.map(Telemetry.metrics(), & &1.name)

    assert [:serviceradar, :managed_devices] in metric_names
    assert [:serviceradar, :collectors, :total] in metric_names
    assert [:serviceradar, :leaf_nodes, :total] in metric_names
  end

  describe "storage/retention gauges (add-tiered-telemetry-offload D10)" do
    @per_table_storage_gauges [
      :hot_bytes,
      :ingest_bytes_per_day,
      :cold_bytes,
      :cold_rows,
      :cold_oldest_available_seconds,
      :frontier_lag_seconds,
      :held_chunks,
      :quarantined_chunks
    ]

    @global_storage_gauges [:database_bytes, :nontelemetry_bytes]

    test "includes every storage gauge in the Prometheus reporter set" do
      metric_names = Enum.map(Telemetry.metrics(), & &1.name)

      for gauge <- @per_table_storage_gauges ++ @global_storage_gauges do
        assert [:serviceradar, :storage, gauge] in metric_names
      end
    end

    test "storage gauges use isolated events with a :value measurement" do
      storage_metrics =
        Enum.filter(Telemetry.metrics(), &match?([:serviceradar, :storage, _gauge], &1.name))

      assert length(storage_metrics) ==
               length(@per_table_storage_gauges) + length(@global_storage_gauges)

      for metric <- storage_metrics do
        assert metric.__struct__ == Elixir.Telemetry.Metrics.LastValue
        assert metric.event_name == metric.name
        assert metric.measurement == :value
      end
    end

    test "per-table storage gauges are tagged by table, globals untagged" do
      metrics_by_name = Map.new(Telemetry.metrics(), &{&1.name, &1})

      for gauge <- @per_table_storage_gauges do
        assert metrics_by_name[[:serviceradar, :storage, gauge]].tags == [:table]
      end

      for gauge <- @global_storage_gauges do
        assert metrics_by_name[[:serviceradar, :storage, gauge]].tags == []
      end
    end
  end

  test "includes prefix-tag health metrics in the Prometheus reporter set" do
    metric_names = Enum.map(Telemetry.metrics(), & &1.name)

    assert [:serviceradar, :prefix_tags, :lookup, :count] in metric_names
    assert [:serviceradar, :prefix_tags, :swap, :duration] in metric_names
    assert [:serviceradar, :prefix_tags, :rebuild, :duration] in metric_names
    assert [:serviceradar, :prefix_tags, :snapshot_age, :age_seconds] in metric_names
    assert [:serviceradar, :prefix_tags, :snapshot_freshness, :known] in metric_names
    assert [:serviceradar, :prefix_tags, :import, :record_count] in metric_names
  end
end
