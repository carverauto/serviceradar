defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.Telemetry do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  @doc false
  @spec canonical_edge_telemetry_batch_query([map()]) :: String.t()
  def canonical_edge_telemetry_batch_query(updates) when is_list(updates) do
    rows_literal = Enum.map_join(updates, ",\n", &canonical_edge_telemetry_update_literal/1)

    """
    UNWIND [#{rows_literal}] AS row
    MATCH (a:Device {id: row.src_id})-[r:CANONICAL_TOPOLOGY]->(b:Device {id: row.dst_id})
    WHERE r.ingestor = 'mapper_topology_v1'
    SET r.flow_pps = row.flow_pps
    SET r.flow_bps = row.flow_bps
    SET r.capacity_bps = row.capacity_bps
    SET r.flow_pps_ab = row.flow_pps_ab
    SET r.flow_pps_ba = row.flow_pps_ba
    SET r.flow_bps_ab = row.flow_bps_ab
    SET r.flow_bps_ba = row.flow_bps_ba
    SET r.telemetry_eligible = row.telemetry_eligible
    SET r.telemetry_source = row.telemetry_source
    SET r.telemetry_observed_at = row.telemetry_observed_at
    """
  end

  defp canonical_edge_telemetry_update_literal(update) when is_map(update) do
    [
      "src_id: #{Utils.cypher_value(Map.get(update, :src_id))}",
      "dst_id: #{Utils.cypher_value(Map.get(update, :dst_id))}",
      "flow_pps: #{Utils.cypher_value(Map.get(update, :flow_pps, 0))}",
      "flow_bps: #{Utils.cypher_value(Map.get(update, :flow_bps, 0))}",
      "capacity_bps: #{Utils.cypher_value(Map.get(update, :capacity_bps, 0))}",
      "flow_pps_ab: #{Utils.cypher_value(Map.get(update, :flow_pps_ab, 0))}",
      "flow_pps_ba: #{Utils.cypher_value(Map.get(update, :flow_pps_ba, 0))}",
      "flow_bps_ab: #{Utils.cypher_value(Map.get(update, :flow_bps_ab, 0))}",
      "flow_bps_ba: #{Utils.cypher_value(Map.get(update, :flow_bps_ba, 0))}",
      "telemetry_eligible: #{Utils.cypher_value(Map.get(update, :telemetry_eligible, false))}",
      "telemetry_source: #{Utils.cypher_value(Map.get(update, :telemetry_source, "none"))}",
      "telemetry_observed_at: #{Utils.cypher_value(Map.get(update, :telemetry_observed_at, ""))}"
    ]
    |> Enum.join(", ")
    |> then(&"{#{&1}}")
  end
end
