defmodule ServiceRadar.Jobs.ReapStalePeriodicJobsWorker do
  @moduledoc """
  Reaps stale periodic Oban jobs that remain stuck in `executing`.

  Periodic jobs are identified by the cron metadata Oban stores on rows enqueued by
  `Oban.Plugins.Cron`. Jobs older than the configured stale threshold are transitioned
  back to `available` or `discarded`, and the cleanup is emitted via telemetry/logs so
  operators can see which workers and job ids were affected.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 300, states: [:available, :scheduled, :retryable]]

  import Ecto.Query, warn: false

  alias Oban.Job
  alias ServiceRadar.Repo

  require Logger

  @default_stale_threshold_minutes 240

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
      %{
        status: status,
        stale_threshold_minutes: stale_threshold_minutes(),
        rescued_jobs: rescued_jobs,
        discarded_jobs: discarded_jobs
      }
      |> maybe_put_reason(reason)

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
        stale_periodic_jobs_query(cutoff)
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

  defp stale_periodic_jobs_query(cutoff) do
    from(j in Job,
      where: j.state == "executing",
      where: not is_nil(j.attempted_at) and j.attempted_at < ^cutoff,
      where: fragment("coalesce(?->>'cron', 'false') = 'true'", j.meta),
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
