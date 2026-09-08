defmodule ServiceRadar.Integrations.ArmisNorthboundConflictAuditWorker do
  @moduledoc """
  Periodic Oban worker that recomputes source-authoritative identity drift once
  globally and persists it to `platform.source_identity_conflicts`.

  This decouples the expensive drift audit (five aggregation queries over
  `device_identifiers ⋈ ocsf_devices` plus a full conflict upsert) from the
  per-source Armis northbound run hot path. The northbound runner now reads the
  persisted open-conflict counts (see `SourceIdentityDrift.source_conflict_report/2`)
  instead of recomputing the audit on every push, so N sources no longer each
  recompute the identical global audit every cycle.

  The worker self-reschedules every `:armis_northbound_conflict_audit_interval_seconds`
  (default 3600) and is Oban-unique on pending states, so at most one audit is
  pending at a time. It is seeded by `ArmisNorthboundScheduler`.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Inventory.SourceIdentityDrift
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_audit_interval_seconds 3600
  @min_reschedule_seconds 60

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:error, term()}
  def ensure_scheduled do
    if support_module().available?() do
      %{} |> new() |> support_module().safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case run_audit() do
      {:error, _reason} ->
        # Already logged in run_audit/0. Stay :ok so Oban does not churn the
        # 3-attempt retry budget on a background diagnostic; the next run is
        # scheduled below and the scheduler re-seeds if this cadence ever drops.
        :ok

      result ->
        Logger.debug("Armis northbound conflict audit completed",
          audited_count: Map.get(result, :audited_count),
          cleared_count: Map.get(result, :cleared_count)
        )
    end

    schedule_next()
  end

  defp run_audit do
    audit_fun().()
  rescue
    error ->
      Logger.warning("Armis northbound conflict audit failed", error: Exception.message(error))
      {:error, error}
  end

  defp schedule_next do
    # The current job is still :executing here. SelfScheduling applies
    # scheduled-only uniqueness for the follow-up so it can be inserted while the
    # worker's default :incomplete uniqueness still protects scheduler seed jobs.
    _ =
      support_module().safe_insert(
        SelfScheduling.successor_changeset(
          __MODULE__,
          %{},
          max(audit_interval_seconds(), @min_reschedule_seconds)
        )
      )

    :ok
  end

  defp audit_interval_seconds do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_conflict_audit_interval_seconds,
      @default_audit_interval_seconds
    )
  end

  defp audit_fun do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_conflict_audit_fun,
      &SourceIdentityDrift.audit_and_persist/0
    )
  end

  defp support_module do
    Application.get_env(:serviceradar_core, :armis_northbound_oban_support_module, ObanSupport)
  end
end
