defmodule ServiceRadar.Jobs.ReapStalePeriodicJobsWorker do
  @moduledoc """
  Reaps stale periodic Oban jobs that remain stuck in `executing`.

  Periodic jobs are identified by two complementary mechanisms:

  - `Oban.Plugins.Cron` stamps `meta.cron = "true"` on the rows it enqueues, and
    the query matches that fragment directly.
  - AshOban triggers enqueue through their own generated scheduler/worker modules
    with **empty meta**, so their worker names are derived at query time from the
    AshOban trigger declarations across all configured domains (see
    `periodic_worker_names/0`). An explicit `@self_scheduled_workers` allowlist
    covers workers that self-schedule by other means.

  Jobs older than the configured stale threshold are transitioned back to `available`
  or `discarded`, and the cleanup is emitted via telemetry/logs so operators can see
  which workers and job ids were affected.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 300, states: :incomplete]

  import Ecto.Query, warn: false

  alias Oban.Job
  alias ServiceRadar.Repo

  require Logger

  @default_stale_threshold_minutes 240
  @self_scheduled_workers [
    "ServiceRadar.Credentials.PluginCredentialRuleReconcileWorker",
    "ServiceRadar.Credentials.PluginIntegrationReconcileWorker",
    "ServiceRadar.Edge.AgentCommandCleanupWorker",
    "ServiceRadar.Identity.CliAuthCleanupWorker",
    "ServiceRadar.Inventory.AdvisoryFeeds.StagingCleanupWorker",
    "ServiceRadar.Inventory.DeviceCleanupWorker",
    "ServiceRadar.Inventory.DeviceRiskAssessmentWorker",
    "ServiceRadar.Inventory.EndpointVulnerabilityMatchWorker",
    "ServiceRadar.Inventory.InterfaceThresholdWorker",
    "ServiceRadar.Jobs.AlertsRetentionWorker",
    "ServiceRadar.Jobs.RefreshTraceSummariesWorker",
    "ServiceRadar.Jobs.RootSpanRatioWorker",
    "ServiceRadar.Jobs.SecurityEventsRetentionWorker",
    "ServiceRadar.NetworkDiscovery.TopologyStateCleanupWorker",
    "ServiceRadar.ObjectStore.RetentionWorker",
    "ServiceRadar.Observability.GeoLiteMmdbDownloadWorker",
    "ServiceRadar.Observability.IpEnrichmentCleanupWorker",
    "ServiceRadar.Observability.IpEnrichmentRefreshWorker",
    "ServiceRadar.Observability.IpinfoMmdbDownloadWorker",
    "ServiceRadar.Observability.NetflowExporterCacheRefreshWorker",
    "ServiceRadar.Observability.NetflowInterfaceCacheRefreshWorker",
    "ServiceRadar.Observability.NetflowSecurityRefreshWorker",
    "ServiceRadar.Observability.StatefulAlertCleanupWorker",
    "ServiceRadar.Observability.ThreatIntelFeedRefreshWorker",
    "ServiceRadar.Plugins.AddonProfileReconcileWorker",
    "ServiceRadar.Plugins.AddonRolloutWorker",
    "ServiceRadar.Plugins.AddonUpdatePolicyBackfillWorker",
    "ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryDispatchWorker",
    "ServiceRadar.Plugins.PluginTargetPolicyReconcileWorker",
    "ServiceRadar.SweepJobs.SweepCoverageRollupWorker",
    "ServiceRadar.SweepJobs.SweepDataCleanupWorker",
    "ServiceRadar.SweepJobs.SweepMonitorWorker",
    "ServiceRadarWebNG.Plugins.BlobRetentionWorker",
    "ServiceRadarWebNG.Plugins.FirstPartySyncWorker"
  ]

  @completed_event [:serviceradar, :jobs, :periodic_cleanup, :completed]
  @failed_event [:serviceradar, :jobs, :periodic_cleanup, :failed]

  @type job_ref :: %{
          id: pos_integer(),
          worker: String.t(),
          queue: String.t(),
          attempt: non_neg_integer(),
          max_attempts: pos_integer()
        }

  @spec stale_threshold_minutes() :: pos_integer()
  def stale_threshold_minutes do
    Application.get_env(
      :serviceradar_core,
      :periodic_job_stale_threshold_minutes,
      @default_stale_threshold_minutes
    )
  end

  @spec emit_cleanup_telemetry(atom(), [job_ref()], [job_ref()], term() | nil) :: :ok
  def emit_cleanup_telemetry(status, rescued_jobs, discarded_jobs, reason \\ nil) do
    event = if status == :completed, do: @completed_event, else: @failed_event

    measurements = %{
      rescued_count: length(rescued_jobs),
      discarded_count: length(discarded_jobs)
    }

    metadata =
      maybe_put_reason(
        %{
          status: status,
          stale_threshold_minutes: stale_threshold_minutes(),
          rescued_jobs: rescued_jobs,
          discarded_jobs: discarded_jobs
        },
        reason
      )

    :telemetry.execute(event, measurements, metadata)
  end

  @impl Oban.Worker
  def perform(_job) do
    case reap_stale_jobs() do
      {:ok, %{rescued_jobs: rescued_jobs, discarded_jobs: discarded_jobs}} ->
        maybe_log_cleanup(rescued_jobs, discarded_jobs)
        emit_cleanup_telemetry(:completed, rescued_jobs, discarded_jobs)
        :ok

      {:error, reason} ->
        Logger.error("Failed to reap stale periodic Oban jobs: #{inspect(reason)}")
        emit_cleanup_telemetry(:failed, [], [], reason)
        {:error, reason}
    end
  end

  @spec reap_stale_jobs() ::
          {:ok, %{rescued_jobs: [job_ref()], discarded_jobs: [job_ref()]}} | {:error, term()}
  def reap_stale_jobs do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -stale_threshold_minutes() * 60, :second)

    Repo.transaction(fn ->
      stale_jobs =
        cutoff
        |> stale_periodic_jobs_query()
        |> Repo.all()

      {rescued_jobs, discarded_jobs} = split_stale_jobs(stale_jobs)

      rescued_ids = Enum.map(rescued_jobs, & &1.id)
      discarded_ids = Enum.map(discarded_jobs, & &1.id)

      maybe_rescue_jobs(rescued_ids)
      maybe_discard_jobs(discarded_ids, now)

      %{
        rescued_jobs: rescued_jobs,
        discarded_jobs: discarded_jobs
      }
    end)
  end

  @spec split_stale_jobs([job_ref()]) :: {[job_ref()], [job_ref()]}
  def split_stale_jobs(stale_jobs) do
    Enum.split_with(stale_jobs, &(&1.attempt < &1.max_attempts))
  end

  @doc """
  Worker names this reaper is allowed to unstick, as stored in `oban_jobs.worker`.

  Periodic work reaches Oban two ways here and only one of them is self-describing.
  `Oban.Plugins.Cron` stamps `meta.cron = "true"`, which the query matches directly.
  An AshOban trigger instead enqueues through its own scheduler/worker modules with
  **empty meta**, so it matched neither that fragment nor the hand-maintained
  `@self_scheduled_workers` list -- every AshOban-backed schedule was invisible to
  the one component whose job is to unstick stranded periodic jobs. A trigger
  stranded in `executing` by a node restart then blocked its own re-enqueue,
  because its uniqueness covers incomplete states, and nothing could clear it.

  Deriving the AshOban names from the trigger declarations rather than listing them
  keeps a newly added trigger covered without anyone remembering to update a list.
  """
  @spec periodic_worker_names() :: [String.t()]
  def periodic_worker_names do
    Enum.uniq(@self_scheduled_workers ++ ash_oban_worker_names())
  end

  defp ash_oban_worker_names do
    :serviceradar_core
    |> Application.get_env(:ash_domains, [])
    |> List.wrap()
    |> Enum.flat_map(&safe_domain_resources/1)
    |> Enum.uniq()
    |> Enum.flat_map(&safe_resource_triggers/1)
    |> Enum.flat_map(fn trigger ->
      [Map.get(trigger, :scheduler_module_name), Map.get(trigger, :worker_module_name)]
    end)
    |> Enum.reject(&is_nil/1)
    # `oban_jobs.worker` holds the aliased form without the "Elixir." prefix, which
    # is what inspect/1 produces for a module atom; to_string/1 would not match.
    |> Enum.map(&inspect/1)
    |> Enum.uniq()
  end

  # A resource without the AshOban extension, or a stale domain entry, must not be
  # able to stop the reap. Reaping fewer jobs is recoverable; crashing the only
  # thing that clears stranded jobs is not.
  defp safe_domain_resources(domain) do
    Ash.Domain.Info.resources(domain)
  rescue
    error ->
      Logger.warning("Skipping domain while listing periodic workers",
        domain: inspect(domain),
        reason: Exception.message(error)
      )

      []
  end

  defp safe_resource_triggers(resource) do
    AshOban.Info.oban_triggers_and_scheduled_actions(resource)
  rescue
    _error -> []
  end

  @doc false
  def stale_periodic_jobs_query(cutoff) do
    from(j in Job,
      where: j.state == "executing",
      where: not is_nil(j.attempted_at) and j.attempted_at < ^cutoff,
      where:
        fragment("coalesce(?->>'cron', 'false') = 'true'", j.meta) or
          j.worker in ^periodic_worker_names(),
      order_by: [asc: j.id],
      select: %{
        id: j.id,
        worker: j.worker,
        queue: j.queue,
        attempt: j.attempt,
        max_attempts: j.max_attempts
      }
    )
  end

  defp maybe_rescue_jobs([]), do: {0, nil}

  defp maybe_rescue_jobs(job_ids) do
    Repo.update_all(
      from(j in Job, where: j.id in ^job_ids),
      set: [state: "available"]
    )
  end

  defp maybe_discard_jobs([], _now), do: {0, nil}

  defp maybe_discard_jobs(job_ids, now) do
    Repo.update_all(
      from(j in Job, where: j.id in ^job_ids),
      set: [state: "discarded", discarded_at: now]
    )
  end

  defp maybe_log_cleanup([], []), do: :ok

  defp maybe_log_cleanup(rescued_jobs, discarded_jobs) do
    rescued_refs = format_job_refs(rescued_jobs)
    discarded_refs = format_job_refs(discarded_jobs)

    Logger.warning(
      "Reaped stale periodic Oban jobs rescued=[#{rescued_refs}] discarded=[#{discarded_refs}]",
      rescued_jobs: rescued_jobs,
      discarded_jobs: discarded_jobs,
      stale_threshold_minutes: stale_threshold_minutes()
    )
  end

  defp format_job_refs(jobs) do
    Enum.map_join(jobs, ", ", fn %{id: id, worker: worker} -> "#{worker}##{id}" end)
  end

  defp maybe_put_reason(metadata, nil), do: metadata
  defp maybe_put_reason(metadata, reason), do: Map.put(metadata, :reason, inspect(reason))
end
