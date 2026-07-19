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

  test "includes prefix-tag health metrics in the Prometheus reporter set" do
    metric_names = Enum.map(Telemetry.metrics(), & &1.name)

    assert [:serviceradar, :prefix_tags, :lookup, :count] in metric_names
    assert [:serviceradar, :prefix_tags, :swap, :duration] in metric_names
    assert [:serviceradar, :prefix_tags, :rebuild, :duration] in metric_names
    assert [:serviceradar, :prefix_tags, :snapshot_age, :age_seconds] in metric_names
    assert [:serviceradar, :prefix_tags, :import, :record_count] in metric_names
  end
end
