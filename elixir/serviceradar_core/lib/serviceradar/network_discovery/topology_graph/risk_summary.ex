defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.RiskSummary do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  @spec project_endpoint_inventory_risk_summary(String.t(), map()) :: :ok
  def project_endpoint_inventory_risk_summary(device_uid, summary)
      when is_binary(device_uid) and is_map(summary) do
    case Utils.non_blank(device_uid) do
      nil ->
        :ok

      uid ->
        DgraphPersist.upsert_risk_summary(
          uid,
          Utils.normalize_endpoint_inventory_risk_summary(summary)
        )
    end
  end

  def project_endpoint_inventory_risk_summary(_device_uid, _summary), do: :ok
end
