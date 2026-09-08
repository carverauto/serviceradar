defmodule ServiceRadar.NetworkDiscovery.TopologyStateCleanupWorker do
  @moduledoc """
  Periodic Oban worker that canonicalizes stale topology endpoint IDs.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.HealthConditions
  alias ServiceRadar.NetworkDiscovery.TopologyStateCleanup
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  # Effective cleanup cadence. The sweep is heavy (9 full UPDATEs + canonical rebuild),
  # so run it hourly rather than every 5 minutes. Overridable via
  # `config :serviceradar_core, __MODULE__, reschedule_seconds: ...`; this constant is
  # the hard fallback when no config is present.
  @default_reschedule_seconds 3_600
  @default_min_canonical_edges 1

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if job_already_scheduled?() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)

    min_canonical_edges =
      config
      |> Keyword.get(:min_canonical_edges, @default_min_canonical_edges)
      |> normalize_positive_int(@default_min_canonical_edges)

    case TopologyStateCleanup.canonicalize_deleted_device_links() do
      {:ok, stats} ->
        Logger.info("Topology state cleanup completed", stats: stats)

      {:error, reason} ->
        Logger.warning("Topology state cleanup failed", reason: inspect(reason))
    end

    run_rebuild_with_recovery(min_canonical_edges)

    _ = ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 60)))
    :ok
  end

  defp run_rebuild_with_recovery(min_canonical_edges) when is_integer(min_canonical_edges) do
    case TopologyGraph.rebuild_canonical_links_from_current_with_stats() do
      {:ok, stats} ->
        emit_cleanup_rebuild_telemetry(:completed, stats, min_canonical_edges)
        maybe_recover_canonical_rebuild(stats, min_canonical_edges)
        :ok

      {:error, reason, stats} ->
        emit_cleanup_rebuild_telemetry(:failed, stats, min_canonical_edges, reason)
        Logger.warning("Canonical topology rebuild failed", reason: inspect(reason), stats: stats)
        :ok
    end
  end

  defp maybe_recover_canonical_rebuild(stats, min_canonical_edges)
       when is_map(stats) and is_integer(min_canonical_edges) do
    after_edges = Map.get(stats, :after_prune_edges, 0)
    mapper_edges = Map.get(stats, :mapper_evidence_edges, 0)

    if recovery_needed?(stats, min_canonical_edges) do
      Logger.warning(
        "Canonical topology below threshold; triggering one-shot recovery rebuild",
        min_canonical_edges: min_canonical_edges,
        after_prune_edges: after_edges,
        mapper_evidence_edges: mapper_edges
      )

      emit_recovery_telemetry(:triggered, stats, min_canonical_edges)

      case TopologyGraph.rebuild_canonical_links_from_current_with_stats() do
        {:ok, retry_stats} ->
          report_recovery_outcome(stats, retry_stats, min_canonical_edges)

        {:error, reason, retry_stats} ->
          emit_recovery_telemetry(:failed, retry_stats, min_canonical_edges, reason)

          Logger.warning(
            "Canonical topology recovery rebuild failed",
            reason: inspect(reason),
            stats: retry_stats
          )
      end
    end
  end

  defp maybe_recover_canonical_rebuild(_stats, _min_canonical_edges), do: :ok

  @doc false
  # Honest recovery outcome (fj #4378): a recovery rebuild that still leaves the
  # canonical edge count below the threshold while mapper evidence exists is a
  # FAILURE — emit failed telemetry and the deduplicated unhealthy condition
  # (shared with CanonicalRebuild's in-rebuild self-heal) instead of the old
  # unconditional "completed" claim. Genuine recovery emits completed, clears
  # the condition, and logs the all-clear.
  @spec report_recovery_outcome(map(), map(), integer(), keyword()) :: :completed | :failed
  def report_recovery_outcome(stats, retry_stats, min_canonical_edges, opts \\ [])
      when is_map(stats) and is_map(retry_stats) and is_integer(min_canonical_edges) do
    condition = Keyword.get(opts, :condition, CanonicalRebuild.self_heal_condition())
    outcome_stats = recovery_outcome_stats(stats, retry_stats)

    if recovery_needed?(outcome_stats, min_canonical_edges) do
      emit_recovery_telemetry(
        :failed,
        outcome_stats,
        min_canonical_edges,
        :canonical_edges_below_threshold
      )

      _ =
        HealthConditions.report_failure(
          condition,
          "Canonical topology recovery rebuild FAILED: canonical edges still below threshold while mapper evidence exists",
          after_prune_edges: Map.get(outcome_stats, :after_prune_edges, 0),
          mapper_evidence_edges: Map.get(outcome_stats, :mapper_evidence_edges, 0),
          min_canonical_edges: min_canonical_edges
        )

      :failed
    else
      emit_recovery_telemetry(:completed, outcome_stats, min_canonical_edges)

      _ =
        HealthConditions.report_recovery(
          condition,
          "Canonical topology recovery rebuild restored canonical edges",
          after_prune_edges: Map.get(outcome_stats, :after_prune_edges, 0),
          min_canonical_edges: min_canonical_edges
        )

      Logger.info("Canonical topology recovery rebuild completed", stats: retry_stats)
      :completed
    end
  end

  @doc false
  # The retry can be skipped by the rebuild's change-detection guard (unchanged
  # fingerprint) or the advisory lock — a skipped run carries no fresh edge
  # counts, and nothing changed, so the pre-retry failing counts still describe
  # reality. Judging the skipped retry's empty stats would count 0 mapper
  # evidence and falsely claim completion at 0 canonical edges.
  @spec recovery_outcome_stats(map(), map()) :: map()
  def recovery_outcome_stats(stats, retry_stats) when is_map(stats) and is_map(retry_stats) do
    if Map.has_key?(retry_stats, :after_prune_edges) do
      retry_stats
    else
      stats
    end
  end

  @doc false
  @spec recovery_needed?(map(), integer()) :: boolean()
  def recovery_needed?(stats, min_canonical_edges)
      when is_map(stats) and is_integer(min_canonical_edges) and min_canonical_edges > 0 do
    after_edges = Map.get(stats, :after_prune_edges, 0)
    mapper_edges = Map.get(stats, :mapper_evidence_edges, 0)
    after_edges < min_canonical_edges and mapper_edges >= min_canonical_edges
  end

  def recovery_needed?(_stats, _min_canonical_edges), do: false

  @doc false
  @spec emit_cleanup_rebuild_telemetry(:completed | :failed, map(), integer(), term() | nil) ::
          :ok
  def emit_cleanup_rebuild_telemetry(status, stats, min_canonical_edges, reason \\ nil)
      when status in [:completed, :failed] and is_map(stats) and is_integer(min_canonical_edges) do
    measurements = %{
      before_edges: Map.get(stats, :before_edges, 0),
      mapper_evidence_edges: Map.get(stats, :mapper_evidence_edges, 0),
      after_upsert_edges: Map.get(stats, :after_upsert_edges, 0),
      after_prune_edges: Map.get(stats, :after_prune_edges, 0),
      min_canonical_edges: min_canonical_edges
    }

    metadata =
      maybe_put_reason(
        %{
          status: status,
          stale_cutoff: Map.get(stats, :stale_cutoff),
          starved: Map.get(stats, :starved, false),
          evidence_max_last_observed_at: Map.get(stats, :evidence_max_last_observed_at)
        },
        reason
      )

    :telemetry.execute(
      [:serviceradar, :topology, :cleanup_rebuild, status],
      measurements,
      metadata
    )

    :ok
  end

  @doc false
  @spec emit_recovery_telemetry(:triggered | :completed | :failed, map(), integer(), term() | nil) ::
          :ok
  def emit_recovery_telemetry(status, stats, min_canonical_edges, reason \\ nil)
      when status in [:triggered, :completed, :failed] and is_map(stats) and
             is_integer(min_canonical_edges) do
    measurements = %{
      mapper_evidence_edges: Map.get(stats, :mapper_evidence_edges, 0),
      after_prune_edges: Map.get(stats, :after_prune_edges, 0),
      min_canonical_edges: min_canonical_edges
    }

    metadata =
      maybe_put_reason(%{status: status, stale_cutoff: Map.get(stats, :stale_cutoff)}, reason)

    :telemetry.execute(
      [:serviceradar, :topology, :cleanup_recovery, status],
      measurements,
      metadata
    )

    :ok
  end

  defp maybe_put_reason(metadata, nil), do: metadata
  defp maybe_put_reason(metadata, reason), do: Map.put(metadata, :reason, inspect(reason))

  defp job_already_scheduled? do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value, default), do: default
end
