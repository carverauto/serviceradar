defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Edges
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Identity
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Refresh
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  @default_canonical_edge_telemetry_batch_size 100

  @doc false
  @spec canonical_edge_telemetry_batch_size() :: pos_integer()
  def canonical_edge_telemetry_batch_size do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(
      :canonical_edge_telemetry_batch_size,
      @default_canonical_edge_telemetry_batch_size
    )
    |> Utils.normalize_positive_int(@default_canonical_edge_telemetry_batch_size)
  end

  defdelegate refresh_canonical_edge_telemetry(stale_cutoff), to: Refresh

  @doc false
  @spec extract_metric_device_ip(term()) :: String.t() | nil
  defdelegate extract_metric_device_ip(value), to: Identity

  @doc false
  @spec edge_render_readiness_class(map()) ::
          :render_ready | :render_partial | :render_unattributed
  defdelegate edge_render_readiness_class(edge), to: Edges
end
