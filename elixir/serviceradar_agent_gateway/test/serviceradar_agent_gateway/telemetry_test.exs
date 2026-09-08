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
end
