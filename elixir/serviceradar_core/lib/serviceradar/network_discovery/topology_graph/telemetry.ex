defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Edges
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Identity
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Refresh

  defdelegate refresh_canonical_edge_telemetry(), to: Refresh

  @doc false
  @spec extract_metric_device_ip(term()) :: String.t() | nil
  defdelegate extract_metric_device_ip(value), to: Identity

  @doc false
  @spec edge_render_readiness_class(map()) ::
          :render_ready | :render_partial | :render_unattributed
  defdelegate edge_render_readiness_class(edge), to: Edges
end
