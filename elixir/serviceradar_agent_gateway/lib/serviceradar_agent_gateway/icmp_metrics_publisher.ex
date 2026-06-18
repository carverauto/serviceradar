defmodule ServiceRadarAgentGateway.IcmpMetricsPublisher do
  @moduledoc false
  use ServiceRadarAgentGateway.MetricsPublisher,
    metric: :icmp,
    log_label: "ICMP",
    descriptor: "ICMP check"
end
