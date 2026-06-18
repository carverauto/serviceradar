defmodule ServiceRadarAgentGateway.SnmpMetricsPublisher do
  @moduledoc false
  use ServiceRadarAgentGateway.MetricsPublisher,
    metric: :snmp,
    log_label: "SNMP",
    descriptor: "SNMP"
end
