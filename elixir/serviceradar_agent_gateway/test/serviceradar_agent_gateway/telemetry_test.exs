defmodule ServiceRadarAgentGateway.TelemetryTest do
  use ExUnit.Case, async: true

  test "uses a stable prometheus reporter name" do
    assert ServiceRadarAgentGateway.Telemetry.prometheus_reporter() ==
             :serviceradar_agent_gateway_prometheus_metrics
  end

  test "exports gateway push, buffering, forwarding, and control-stream metrics" do
    metric_names = Enum.map(ServiceRadarAgentGateway.Telemetry.metrics(), & &1.name)

    assert [:serviceradar, :agent_gateway, :push, :complete, :count] in metric_names
    assert [:serviceradar, :agent_gateway, :push, :services, :count] in metric_names
    assert [:serviceradar, :agent_gateway, :results, :forward, :count] in metric_names
    assert [:serviceradar, :agent_gateway, :results, :forward, :duration] in metric_names
    assert [:serviceradar, :agent_gateway, :results, :buffer, :dropped, :count] in metric_names
    assert [:serviceradar, :agent_gateway, :results, :buffer, :dropped, :bytes] in metric_names
    assert [:serviceradar, :agent_gateway, :results, :buffer, :depth] in metric_names
    assert [:serviceradar, :agent_gateway, :results, :buffer, :bytes] in metric_names
    assert [:serviceradar, :agent_gateway, :control_stream, :established, :count] in metric_names
    assert [:serviceradar, :agent_gateway, :control_stream, :closed, :count] in metric_names
    assert [:serviceradar, :agent_gateway, :control_stream, :active, :count] in metric_names
  end

  test "starts :opentelemetry_exporter before :opentelemetry in the compiled application spec" do
    assert ServiceRadarAgentGateway.Telemetry.prometheus_reporter() ==
             :serviceradar_agent_gateway_prometheus_metrics

    apps = Application.spec(:serviceradar_agent_gateway, :applications)
    exporter_idx = Enum.find_index(apps, &(&1 == :opentelemetry_exporter))
    otel_idx = Enum.find_index(apps, &(&1 == :opentelemetry))

    assert is_integer(exporter_idx)
    assert is_integer(otel_idx)
    assert exporter_idx < otel_idx
  end
end
