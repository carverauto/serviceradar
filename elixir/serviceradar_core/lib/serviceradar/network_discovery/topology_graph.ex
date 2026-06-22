defmodule ServiceRadar.NetworkDiscovery.TopologyGraph do
  @moduledoc """
  Projects mapper topology links into the Apache AGE graph.
  """

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Interfaces
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Links
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Projection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.RiskSummary
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry

  @type projection_payload :: Projection.projection_payload()

  @spec upsert_links([map()]) :: :ok
  defdelegate upsert_links(links), to: Links

  @doc """
  Rebuilds canonical device-level topology edges from current mapper evidence in AGE.
  """
  @spec rebuild_canonical_links_from_current() :: :ok
  defdelegate rebuild_canonical_links_from_current(), to: CanonicalRebuild

  @doc """
  Rebuilds canonical device-level topology edges from current mapper evidence in AGE and
  returns rebuild counters for observability/recovery decisions.
  """
  @spec rebuild_canonical_links_from_current_with_stats() ::
          {:ok, map()} | {:error, term(), map()}
  defdelegate rebuild_canonical_links_from_current_with_stats(), to: CanonicalRebuild

  @doc """
  Returns projection diagnostics for a batch without mutating AGE.
  """
  @spec projection_diagnostics([map()]) :: %{
          accepted: map(),
          rejected: map(),
          total: non_neg_integer()
        }
  defdelegate projection_diagnostics(links), to: Projection

  @doc """
  Pure classifier for mapper topology projection decisions.

  Returns:
  - `{:ok, %{mode: :backbone, relation: "CONNECTS_TO", payload: payload}}`
  - `{:ok, %{mode: :auxiliary, relation: "ATTACHED_TO" | "INFERRED_TO" | "OBSERVED_TO", payload: payload}}`
  - `{:ok, %{mode: :skip, relation: nil, payload: payload}}`
  - `{:error, :missing_ids}` when required identifiers are absent
  """
  @spec classify_projection(map()) ::
          {:ok,
           %{
             mode: :backbone | :auxiliary | :skip,
             relation: String.t() | nil,
             payload: projection_payload()
           }}
          | {:error, :missing_ids}
  defdelegate classify_projection(link), to: Projection

  @spec upsert_interfaces([map()]) :: :ok
  defdelegate upsert_interfaces(interfaces), to: Interfaces

  @doc """
  Creates a MANAGED_BY edge from a device to its management device, plus the
  reverse MANAGES edge (Gap D) so the causal engine can traverse manager ->
  managed directly (e.g. C4 management-unobservable / C5 redundancy reasoning)
  without scanning every MANAGED_BY edge in reverse.
  """
  @spec upsert_managed_by(String.t(), String.t()) :: :ok
  defdelegate upsert_managed_by(device_uid, management_device_uid), to: Interfaces

  @doc """
  Projects endpoint-inventory vulnerability risk onto the canonical Device vertex.

  The `pkg_*` properties are topology-structure-invariant: they are bounded scalar
  annotations used by causal readers and must not create package vertices, package
  edges, or topology adjacency.
  """
  @spec project_endpoint_inventory_risk_summary(String.t(), map(), keyword()) :: :ok
  defdelegate project_endpoint_inventory_risk_summary(device_uid, summary, opts \\ []),
    to: RiskSummary

  @doc false
  @spec endpoint_inventory_risk_summary_query(String.t(), map()) :: String.t() | nil
  defdelegate endpoint_inventory_risk_summary_query(device_uid, summary), to: Queries

  @doc false
  @spec endpoint_inventory_risk_summary_fields() :: [atom()]
  defdelegate endpoint_inventory_risk_summary_fields(), to: Queries

  @doc false
  @spec backbone_link_upsert_query(map()) :: String.t()
  defdelegate backbone_link_upsert_query(payload), to: Queries

  @doc false
  @spec auxiliary_link_upsert_query(map(), String.t()) :: String.t()
  defdelegate auxiliary_link_upsert_query(payload, relation), to: Queries

  @doc false
  @spec prune_unseen_projected_links_queries(String.t(), Enumerable.t()) :: [String.t()]
  defdelegate prune_unseen_projected_links_queries(local_device_id, neighbor_ids), to: Queries

  @doc false
  @spec prune_unseen_projected_forward_links_query(String.t(), Enumerable.t()) :: String.t()
  defdelegate prune_unseen_projected_forward_links_query(local_device_id, neighbor_ids),
    to: Queries

  @doc false
  @spec prune_unseen_projected_reverse_links_query(String.t(), Enumerable.t()) :: String.t()
  defdelegate prune_unseen_projected_reverse_links_query(local_device_id, neighbor_ids),
    to: Queries

  @doc false
  @spec prune_stale_mapper_evidence_links_query(String.t()) :: String.t()
  defdelegate prune_stale_mapper_evidence_links_query(stale_cutoff), to: Queries

  @doc false
  @spec reconcile_legacy_single_identifier_attachment_links_query() :: String.t()
  defdelegate reconcile_legacy_single_identifier_attachment_links_query(), to: Queries

  @doc false
  @spec purge_legacy_single_identifier_canonical_links_query() :: String.t()
  defdelegate purge_legacy_single_identifier_canonical_links_query(), to: Queries

  @doc false
  @spec canonical_rebuild_timeout_ms() :: pos_integer()
  defdelegate canonical_rebuild_timeout_ms(), to: CanonicalRebuild

  @doc false
  @spec canonical_edge_telemetry_batch_size() :: pos_integer()
  defdelegate canonical_edge_telemetry_batch_size(), to: Telemetry

  @doc false
  @spec canonical_edge_telemetry_batch_query([map()]) :: String.t()
  defdelegate canonical_edge_telemetry_batch_query(updates), to: Queries

  @doc false
  @spec canonical_rebuild_min_edges() :: pos_integer()
  defdelegate canonical_rebuild_min_edges(), to: CanonicalRebuild

  @doc false
  @spec self_heal_needed?(integer(), integer(), integer()) :: boolean()
  defdelegate self_heal_needed?(after_prune_edges, mapper_evidence_edges, min_canonical_edges),
    to: CanonicalRebuild

  @doc false
  @spec emit_canonical_rebuild_telemetry(:completed | :failed, map(), term() | nil) :: :ok
  defdelegate emit_canonical_rebuild_telemetry(status, stats, reason \\ nil),
    to: CanonicalRebuild

  @doc false
  @spec canonical_edge_count_query() :: String.t()
  defdelegate canonical_edge_count_query(), to: Queries

  @doc false
  @spec mapper_evidence_edge_count_query() :: String.t()
  defdelegate mapper_evidence_edge_count_query(), to: Queries

  @doc false
  @spec extract_metric_device_ip(term()) :: String.t() | nil
  defdelegate extract_metric_device_ip(value), to: Telemetry

  @doc false
  @spec edge_render_readiness_class(map()) ::
          :render_ready | :render_partial | :render_unattributed
  defdelegate edge_render_readiness_class(edge), to: Telemetry

  @doc false
  @spec canonical_rebuild_upsert_query(String.t()) :: String.t()
  defdelegate canonical_rebuild_upsert_query(stale_cutoff), to: Queries

  @doc false
  @spec canonical_rebuild_prune_query(String.t()) :: String.t()
  defdelegate canonical_rebuild_prune_query(stale_cutoff), to: Queries

  @doc false
  @spec prune_stale_projected_links_enabled?() :: boolean()
  defdelegate prune_stale_projected_links_enabled?(),
    to: ServiceRadar.NetworkDiscovery.TopologyGraph.Pruning
end
