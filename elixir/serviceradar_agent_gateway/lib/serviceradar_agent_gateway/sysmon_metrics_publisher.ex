defmodule ServiceRadarAgentGateway.SysmonMetricsPublisher do
  @moduledoc false
  use ServiceRadarAgentGateway.MetricsPublisher,
    metric: :sysmon,
    log_label: "sysmon",
    descriptor: "sysmon"
end
