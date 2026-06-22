defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics do
  @moduledoc false

  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Identity
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Processes
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Sections

  defdelegate load_process_metrics(srql_module, filter_tokens, scope), to: Processes

  def load_metric_sections(srql_module, filter_tokens, scope, opts \\ []) do
    Sections.load_metric_sections(srql_module, filter_tokens, scope, opts)
  end

  defdelegate sysmon_identity(device_row, device_uid), to: Identity

  defdelegate resolve_sysmon_filter_tokens(srql_module, identity, scope), to: Identity
end
