defmodule ServiceRadarAgentGateway.SweepMetricsPublisher do
  @moduledoc false
  use ServiceRadarAgentGateway.MetricsPublisher,
    metric: :sweep,
    log_label: "sweep",
    descriptor: "sweep scalar",
    producer_kind: "sweep"
end
