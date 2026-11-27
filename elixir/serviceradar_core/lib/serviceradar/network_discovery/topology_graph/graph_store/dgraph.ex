defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.GraphStore.Dgraph do
  @moduledoc """
  Default `TopologyGraph.GraphStore` adapter backed by Dgraph via
  `DgraphPersist` (internal topology) and `ServiceRadar.Dgraph.ExternalTopology`
  (Horizon external topology + bounded multi-hop queries).
  """

  @behaviour ServiceRadar.NetworkDiscovery.TopologyGraph.GraphStore

  alias ServiceRadar.Dgraph.ExternalTopology
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Store

  @impl true
  def writable?, do: Store.writable?()

  @impl true
  def upsert_interfaces(payloads), do: DgraphPersist.upsert_interfaces(payloads)

  @impl true
  def upsert_links(projected), do: DgraphPersist.upsert_links(projected)

  @impl true
  def upsert_managed_by(child, mgmt), do: DgraphPersist.upsert_managed_by(child, mgmt)

  @impl true
  def upsert_mtr_path(attrs), do: DgraphPersist.upsert_mtr_path(attrs)

  @impl true
  def upsert_risk_summary(device_uid, summary),
    do: DgraphPersist.upsert_risk_summary(device_uid, summary)

  @impl true
  def project_config_facts(payloads), do: DgraphPersist.project_config_facts(payloads)

  @impl true
  def prune_stale(cutoff, kinds), do: DgraphPersist.prune_stale(cutoff, kinds)

  @impl true
  def upsert_external_topology(snapshot, _opts \\ []) when is_map(snapshot) do
    if writable?() do
      ExternalTopology.upsert_external_topology(snapshot)
    else
      {:ok, %{nodes_upserted: 0, edges_upserted: 0, edges_skipped: 0}}
    end
  end

  @impl true
  def upsert_external_status(patch, _opts \\ []) when is_map(patch) do
    if writable?() do
      ExternalTopology.upsert_external_status(patch)
    else
      :ok
    end
  end

  @impl true
  def prune_stale_external(cutoff, _opts \\ []) when is_binary(cutoff) do
    if writable?() do
      ExternalTopology.prune_stale_external(cutoff)
    else
      {:ok, 0}
    end
  end

  @impl true
  def blast_radius(%{id: seed_id}, opts), do: blast_radius(seed_id, opts)
  def blast_radius(%{"id" => seed_id}, opts), do: blast_radius(seed_id, opts)

  def blast_radius(seed_id, opts) when is_binary(seed_id) and is_list(opts) do
    if writable?() do
      ExternalTopology.blast_radius(seed_id, opts)
    else
      {:error, :graph_store_unavailable}
    end
  end

  def blast_radius(_seed, _opts), do: {:error, "seed id must be a string"}

  @impl true
  def shared_fate_spofs(opts \\ []) when is_list(opts) do
    if writable?() do
      ExternalTopology.shared_fate_spofs(opts)
    else
      {:error, :graph_store_unavailable}
    end
  end

  @impl true
  def customer_cone_impact(asn, opts \\ []) when is_list(opts) do
    if writable?() do
      ExternalTopology.customer_cone_impact(asn, opts)
    else
      {:error, :graph_store_unavailable}
    end
  end

  @impl true
  def multi_hop_trace(query, opts \\ []) when is_map(query) and is_list(opts) do
    src_id = query[:from] || query["from"] || query[:src_id] || query["src_id"]
    dst_id = query[:to] || query["to"] || query[:dst_id] || query["dst_id"]

    cond do
      not is_binary(src_id) or String.trim(src_id) == "" ->
        {:error, "multi_hop_trace requires a non-empty source identifier"}

      writable?() ->
        ExternalTopology.multi_hop_trace(src_id, dst_id, opts)

      true ->
        {:error, :graph_store_unavailable}
    end
  end

  @impl true
  def egress_topology(opts \\ []) when is_list(opts) do
    if writable?() do
      ExternalTopology.egress_topology(opts)
    else
      {:error, :graph_store_unavailable}
    end
  end
end
