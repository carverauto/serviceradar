defmodule ServiceRadarAgentGateway.MtrMetricsPublisher do
  @moduledoc false
  use ServiceRadarAgentGateway.MetricsPublisher,
    metric: :mtr,
    log_label: "MTR",
    descriptor: "MTR scalar",
    producer_kind: "mtr-checker"
end
