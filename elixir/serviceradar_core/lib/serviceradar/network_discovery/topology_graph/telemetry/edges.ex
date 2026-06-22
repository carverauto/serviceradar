defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Edges do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  def fetch_canonical_edges(stale_cutoff) when is_binary(stale_cutoff) do
    cypher = """
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND (r.last_observed_at IS NULL OR r.last_observed_at >= '#{Graph.escape(stale_cutoff)}')
      AND a.id IS NOT NULL
      AND b.id IS NOT NULL
      AND a.id STARTS WITH 'sr:'
      AND b.id STARTS WITH 'sr:'
    RETURN {
      src_id: a.id,
      dst_id: b.id,
      local_if_index: r.local_if_index,
      neighbor_if_index: r.neighbor_if_index,
      local_if_index_ab: r.local_if_index_ab,
      local_if_index_ba: r.local_if_index_ba
    }
    """

    case Graph.query(cypher) do
      {:ok, rows} when is_list(rows) -> {:ok, Enum.flat_map(rows, &parse_canonical_edge_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp parse_canonical_edge_row(row) do
    src_id = Utils.map_value(row, :src_id)
    dst_id = Utils.map_value(row, :dst_id)

    with true <- is_binary(src_id),
         true <- is_binary(dst_id) do
      local_if_index_ab = Utils.parse_ifindex(Utils.map_value(row, :local_if_index_ab))
      local_if_index_ba = Utils.parse_ifindex(Utils.map_value(row, :local_if_index_ba))
      local_if_index = Utils.parse_ifindex(Utils.map_value(row, :local_if_index))
      neighbor_if_index = Utils.parse_ifindex(Utils.map_value(row, :neighbor_if_index))

      [
        %{
          src_id: src_id,
          dst_id: dst_id,
          local_if_index_ab: local_if_index_ab || local_if_index,
          local_if_index_ba: local_if_index_ba || neighbor_if_index,
          local_if_index: local_if_index,
          neighbor_if_index: neighbor_if_index
        }
      ]
    else
      _ -> []
    end
  end
end
