defmodule ServiceRadar.ColdTier.Health do
  @moduledoc """
  Surfaces cold-tier conditions through the existing infrastructure health
  path (OpenSpec add-tiered-telemetry-offload, task 3.3).

  Logs alone are not an alerting surface. These checks ride
  `ServiceRadar.Observability.TripwireHealth` — the same mechanism the
  anomaly tripwires use — so cold-tier conditions land on the health
  timeline, broadcast over `HealthPubSub`, and publish `health.state_change`
  OCSF logs that existing alert rules can match. The tracker dedupes
  unchanged states, so a persistently stalled export records one transition
  rather than one row per run.

  Checks (all `:core` entity health):

    * `cold-tier-export` — unhealthy when chunks are quarantined (the
      frontier is blocked and needs the break-glass path) or the export
      frontier has fallen far behind its target lag.
    * `cold-tier-pressure` — unhealthy when the primary volume crosses the
      warning threshold while data is held past retention awaiting export.
    * `cold-tier-fence` — unhealthy when an in-database retention policy has
      reappeared on a fenced table, when the cold tier is disabled with
      un-drained state, or when stale CAGG invalidations are pending.

  Recording is best-effort (TripwireHealth swallows write failures), so a
  degraded health surface can never break the exporter reporting through it.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.ColdTier.Config
  alias ServiceRadar.ColdTier.PressureMonitor
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.ColdTier.RetentionFence
  alias ServiceRadar.Observability.TripwireHealth

  require Logger

  @export_check "cold-tier-export"
  @pressure_check "cold-tier-pressure"
  @fence_check "cold-tier-fence"

  # Frontier is targeted at now - export_lag; allow a generous multiple
  # before calling it stalled (a single slow run must not flap the check).
  @frontier_lag_tolerance 3
  @pressure_unhealthy_pct 85

  @doc """
  Record all cold-tier health checks. Takes the pressure report the exporter
  already computed to avoid re-running the sizing queries.
  """
  @spec record_all(PressureMonitor.report() | nil, keyword()) :: :ok
  def record_all(pressure_report \\ nil, opts \\ []) do
    recorder = Keyword.get(opts, :health_recorder, &TripwireHealth.record/3)

    record_export(recorder, opts)
    record_pressure(recorder, pressure_report || PressureMonitor.check())
    record_fence(recorder, opts)

    :ok
  end

  @doc """
  Record an unhealthy export path because the analytics head could not be
  reached/set up (review F10). The exporter calls this on its failure branch,
  where a normal `record_all/2` would run head-dependent checks that can't
  complete — but the pressure check (primary-side) still must, since a down
  head is exactly when the primary is at risk.
  """
  @spec record_head_failure(term(), PressureMonitor.report() | nil, keyword()) :: :ok
  def record_head_failure(reason, pressure_report \\ nil, opts \\ []) do
    recorder = Keyword.get(opts, :health_recorder, &TripwireHealth.record/3)

    recorder.(@export_check, false, %{
      head_available: false,
      reason: inspect(reason),
      remediation: "Analytics head unreachable — see docs/cold-tier-runbook.md (exports stalled)"
    })

    record_pressure(recorder, pressure_report || PressureMonitor.check())
    record_fence(recorder, opts)

    :ok
  end

  defp record_export(recorder, opts) do
    quarantined = quarantined_chunks(opts)
    stalled = stalled_frontiers(opts)

    healthy? = quarantined == [] and stalled == []

    recorder.(@export_check, healthy?, %{
      quarantined_tables: Enum.map(quarantined, & &1.table),
      quarantined_chunks: Enum.sum(Enum.map(quarantined, & &1.chunks)),
      stalled_frontiers: Enum.map(stalled, & &1.table),
      remediation:
        if(healthy?,
          do: nil,
          else: "See docs/cold-tier-runbook.md — exports stalled or a chunk is quarantined"
        )
    })
  end

  defp record_pressure(recorder, report) do
    held_bytes = report.held |> Enum.map(& &1.bytes) |> Enum.sum()
    pct = report.usage_pct

    healthy? = is_nil(pct) or pct < @pressure_unhealthy_pct or held_bytes == 0

    recorder.(@pressure_check, healthy?, %{
      usage_pct: pct,
      database_bytes: report.database_bytes,
      volume_bytes: report.volume_bytes,
      held_bytes: held_bytes,
      held_tables: Enum.map(report.held, & &1.table),
      remediation:
        if(healthy?,
          do: nil,
          else:
            "Primary volume filling while data is held for export — see docs/cold-tier-runbook.md"
        )
    })
  end

  defp record_fence(recorder, opts) do
    # A check that cannot run is treated as unhealthy, never as clean: if we
    # cannot confirm the fence is intact, we must not report that it is
    # (review F07). {:error, _} surfaces as a violation the operator sees.
    {violations, check_failed?} =
      case RetentionFence.policy_violations(opts) do
        {:ok, tables} -> {tables, false}
        {:error, _} -> {["<policy check failed>"], true}
      end

    undrained = RetentionFence.undrained_tables(opts)
    stale = RetentionFence.stale_invalidations(opts)

    healthy? = violations == [] and not check_failed? and undrained == [] and stale == []

    recorder.(@fence_check, healthy?, %{
      policy_violations: violations,
      undrained_tables: undrained,
      stale_invalidation_tables: Enum.map(stale, & &1.table),
      remediation:
        if(healthy?,
          do: nil,
          else: "Retention fence integrity — see docs/cold-tier-runbook.md"
        )
    })
  end

  defp quarantined_chunks(opts) do
    repo = Keyword.get(opts, :repo, ServiceRadar.Repo)

    case SQL.query(
           repo,
           """
           SELECT table_name, count(*)
           FROM platform.cold_chunk_exports
           WHERE status = 'quarantined'
           GROUP BY table_name
           """,
           [],
           timeout: 30_000
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [table, count] -> %{table: table, chunks: count} end)

      _ ->
        []
    end
  end

  defp stalled_frontiers(opts) do
    repo = Keyword.get(opts, :repo, ServiceRadar.Repo)
    tolerance_hours = Config.export_lag_hours() * @frontier_lag_tolerance

    case SQL.query(
           repo,
           """
           SELECT table_name, extract(epoch FROM (now() - frontier)) / 3600.0
           FROM platform.cold_tier_boundaries
           WHERE frontier IS NOT NULL
             AND frontier < now() - ($1 * INTERVAL '1 hour')
           """,
           [tolerance_hours],
           timeout: 30_000
         ) do
      {:ok, %{rows: rows}} ->
        # Only registry tables that actually have data can stall: a table
        # with no chunks reports its frontier at now() and never appears.
        for [table, lag_hours] <- rows, Registry.member?(table) do
          %{table: table, lag_hours: lag_hours}
        end

      _ ->
        []
    end
  end
end
