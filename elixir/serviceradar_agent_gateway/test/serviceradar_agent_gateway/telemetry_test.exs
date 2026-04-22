defmodule ServiceRadarAgentGateway.TelemetryTest do
  use ExUnit.Case, async: true

  test "uses a stable prometheus reporter name" do
    assert ServiceRadarAgentGateway.Telemetry.prometheus_reporter() ==
             :serviceradar_agent_gateway_prometheus_metrics
  end

  test "exports gateway push and forwarding metrics" do
    metric_names = Enum.map(ServiceRadarAgentGateway.Telemetry.metrics(), & &1.name)

    assert [:serviceradar, :agent_gateway, :push, :complete, :count] in metric_names
    assert [:serviceradar, :agent_gateway, :push, :services, :count] in metric_names
    assert [:serviceradar, :agent_gateway, :results, :forward, :count] in metric_names
    assert [:serviceradar, :agent_gateway, :results, :forward, :duration] in metric_names
  end
end
