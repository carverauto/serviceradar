defmodule ServiceRadarAgentGateway.RperfMetricsPublisher do
  @moduledoc false
  use ServiceRadarAgentGateway.MetricsPublisher,
    metric: :rperf,
    log_label: "rperf",
    descriptor: "rperf",
    producer_kind: "rperf-checker"
end
