defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.RiskSummary do
  @moduledoc false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries

  require Logger

  @spec project_endpoint_inventory_risk_summary(String.t(), map(), keyword()) :: :ok
  def project_endpoint_inventory_risk_summary(device_uid, summary, opts \\ [])

  def project_endpoint_inventory_risk_summary(device_uid, summary, opts)
      when is_binary(device_uid) and is_map(summary) do
    case Queries.endpoint_inventory_risk_summary_query(device_uid, summary) do
      nil ->
        :ok

      cypher ->
        case Graph.execute(cypher, opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Endpoint inventory risk summary graph projection failed: #{inspect(reason)}"
            )
        end
    end
  end

  def project_endpoint_inventory_risk_summary(_device_uid, _summary, _opts), do: :ok
end
