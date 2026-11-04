defmodule ServiceRadar.NetworkDiscovery.TopologyGraph do
  @moduledoc """
  Projects mapper topology links into the Dgraph topology graph. Writes go
  through typed `ServiceRadar.Dgraph` operations.
  """

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Interfaces
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Links
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Projection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.RiskSummary
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry

  @type projection_payload :: Projection.projection_payload()

  @doc """
  Projects one mapper topology report: every link into Dgraph in one batch.
  It prunes nothing; pruning and the canonical rebuild are the graph-wide
  passes in `run_global_passes/0`.
  Returns `{:error, reason}` when the Dgraph batch fails, so the caller can
  retry the whole idempotent apply.

  A report whose resolved values match the last one this node applied for the
  same devices is skipped for up to the unchanged-report heartbeat. Pass
  `force: true` to apply it regardless.
  """
  @spec upsert_links([map()], keyword()) :: :ok | {:error, term()}
  defdelegate upsert_links(links, opts \\ []), to: Links

  @doc """
  Runs the graph-wide pruning, legacy reconciliation and canonical rebuild that
  follow link projection.
  """
  @spec run_global_passes() :: :ok | {:error, term()}
  defdelegate run_global_passes(), to: Links

  @doc """
  Rebuilds canonical device-level topology edges from current mapper evidence.
  """
  @spec rebuild_canonical_links_from_current() :: :ok
  defdelegate rebuild_canonical_links_from_current(), to: CanonicalRebuild

  @doc """
  Rebuilds canonical device-level topology edges from current mapper evidence and
  returns rebuild counters for observability/recovery decisions.
  """
  @spec rebuild_canonical_links_from_current_with_stats() ::
          {:ok, map()} | {:error, term(), map()}
  defdelegate rebuild_canonical_links_from_current_with_stats(), to: CanonicalRebuild

  @doc """
  Returns projection diagnostics for a batch without mutating the graph.
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

  @doc """
  Projects mapper interfaces in one Dgraph request that writes each device once
  with all of its interfaces. Returns
  `{:error, reason}` when the Dgraph request fails.
  """
  @spec upsert_interfaces([map()]) :: :ok | {:error, term()}
  defdelegate upsert_interfaces(interfaces), to: Interfaces

  @doc """
  Creates a MANAGED_BY edge from a device to its management device, plus the
  reverse MANAGES edge so the causal engine can traverse manager ->
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
  @spec project_endpoint_inventory_risk_summary(String.t(), map()) :: :ok
  defdelegate project_endpoint_inventory_risk_summary(device_uid, summary), to: RiskSummary

  @doc false
  @spec canonical_rebuild_timeout_ms() :: pos_integer()
  defdelegate canonical_rebuild_timeout_ms(), to: CanonicalRebuild

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
  @spec extract_metric_device_ip(term()) :: String.t() | nil
  defdelegate extract_metric_device_ip(value), to: Telemetry

  @doc false
  @spec edge_render_readiness_class(map()) ::
          :render_ready | :render_partial | :render_unattributed
  defdelegate edge_render_readiness_class(edge), to: Telemetry

  @doc false
  @spec prune_stale_projected_links_enabled?() :: boolean()
  defdelegate prune_stale_projected_links_enabled?(),
    to: ServiceRadar.NetworkDiscovery.TopologyGraph.Pruning
end
