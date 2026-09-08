defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.RiskSummary do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  @endpoint_inventory_risk_summary_fields [
    :pkg_worst_severity,
    :pkg_critical_count,
    :pkg_kev_count,
    :pkg_has_unpatched_rce,
    :pkg_risk_summary_at
  ]

  @doc false
  @spec endpoint_inventory_risk_summary_query(String.t(), map()) :: String.t() | nil
  def endpoint_inventory_risk_summary_query(device_uid, summary)
      when is_binary(device_uid) and is_map(summary) do
    case Utils.non_blank(device_uid) do
      nil ->
        nil

      uid ->
        summary = Utils.normalize_endpoint_inventory_risk_summary(summary)

        """
        MERGE (d:Device {id: '#{Graph.escape(uid)}'})
        SET d.pkg_worst_severity = #{Utils.cypher_value(summary.pkg_worst_severity)}
        SET d.pkg_critical_count = #{Utils.cypher_value(summary.pkg_critical_count)}
        SET d.pkg_kev_count = #{Utils.cypher_value(summary.pkg_kev_count)}
        SET d.pkg_has_unpatched_rce = #{Utils.cypher_value(summary.pkg_has_unpatched_rce)}
        SET d.pkg_risk_summary_at = #{Utils.cypher_value(summary.pkg_risk_summary_at)}
        """
    end
  end

  def endpoint_inventory_risk_summary_query(_device_uid, _summary), do: nil

  @doc false
  @spec endpoint_inventory_risk_summary_fields() :: [atom()]
  def endpoint_inventory_risk_summary_fields, do: @endpoint_inventory_risk_summary_fields
end
