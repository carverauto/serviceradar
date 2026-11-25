defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.GraphStore do
  @moduledoc """
  Storage boundary for internal and stitched external topology graph operations.

  Decouples `TopologyGraph`, `MtrGraph`, Horizon JetStream projectors, and MCP
  reasoning tools from the underlying graph backend (`GraphStore.Dgraph` today,
  replaceable via `:serviceradar_core, ServiceRadar.NetworkDiscovery.TopologyGraph, :graph_store`).
  """

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.GraphStore.Dgraph

  @callback writable?() :: boolean()
  @callback upsert_interfaces([map()]) :: :ok | {:error, term()}
  @callback upsert_links([{map(), String.t()}]) :: :ok | {:error, term()}
  @callback upsert_managed_by(String.t(), String.t()) :: :ok
  @callback upsert_mtr_path(map()) :: :ok
  @callback upsert_risk_summary(String.t(), map()) :: :ok
  @callback project_config_facts(map()) :: :ok
  @callback prune_stale(String.t(), [String.t()]) :: :ok

  @callback upsert_external_topology(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback upsert_external_status(map(), keyword()) :: :ok | {:error, term()}
  @callback prune_stale_external(String.t(), keyword()) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback blast_radius(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback shared_fate_spofs(keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback customer_cone_impact(pos_integer() | String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback multi_hop_trace(map(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Returns the configured `GraphStore` adapter module, defaulting to
  `ServiceRadar.NetworkDiscovery.TopologyGraph.GraphStore.Dgraph`.
  """
  @spec adapter() :: module()
  def adapter do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.NetworkDiscovery.TopologyGraph, [])
    |> Keyword.get(:graph_store, Dgraph)
  end
end
