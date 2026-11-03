defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Edges do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  def edge_render_readiness_class(edge) when is_map(edge) do
    src_if_index =
      Utils.parse_ifindex(Map.get(edge, :local_if_index_ab) || Map.get(edge, :local_if_index))

    dst_if_index =
      Utils.parse_ifindex(Map.get(edge, :local_if_index_ba) || Map.get(edge, :neighbor_if_index))

    cond do
      is_integer(src_if_index) and is_integer(dst_if_index) -> :render_ready
      is_integer(src_if_index) or is_integer(dst_if_index) -> :render_partial
      true -> :render_unattributed
    end
  end

  def edge_render_readiness_class(_edge), do: :render_unattributed
end
