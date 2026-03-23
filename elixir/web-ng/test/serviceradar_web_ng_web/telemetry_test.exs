defmodule ServiceRadarWebNGWeb.TelemetryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Telemetry

  test "includes camera relay metrics in the Prometheus reporter set" do
    metric_names = Enum.map(Telemetry.metrics(), & &1.name)

    assert [:serviceradar, :camera_relay, :session, :opened, :count] in metric_names
    assert [:serviceradar, :camera_relay, :session, :closing, :count] in metric_names
    assert [:serviceradar, :camera_relay, :session, :closed, :count] in metric_names
    assert [:serviceradar, :camera_relay, :session, :failed, :count] in metric_names
    assert [:serviceradar, :camera_relay, :session, :viewer_count] in metric_names
  end
end
