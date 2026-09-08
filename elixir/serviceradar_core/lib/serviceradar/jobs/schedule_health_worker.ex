defmodule ServiceRadar.Jobs.ScheduleHealthWorker do
  @moduledoc """
  Periodic Oban worker that alerts when `ng_job_schedules` rows go stale.

  The cron rows in `ng_job_schedules` (e.g. the 5-minute
  `device_identity_reconciliation` schedule) are enqueued by the AshOban
  scheduler. When that pipeline breaks — as it did on 2026-02-06, when an
  RBAC policy change silently filtered the scheduler's nil-actor read to
  zero rows — nothing fires and nothing alerts. This worker closes that
  gap: every run (default 15 minutes) it reads all enabled schedules and,
  for any whose `last_enqueued_at` is older than 2x its cron interval,
  emits `[:serviceradar, :job_schedule, :health, :stale]` and logs a
  warning. A `[:serviceradar, :job_schedule, :health, :run]` summary is
  emitted each run.

  Detection logic lives in `ServiceRadar.Jobs.ScheduleHealthCheck`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Jobs.JobSchedule
  alias ServiceRadar.Jobs.ScheduleHealthCheck
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_reschedule_seconds 900

  @spec ensure_scheduled() :: {:ok, Oban.Job.t() | :already_scheduled} | {:error, term()}
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

    _ = run_check()

    reschedule(config)
    :ok
  end

  @doc """
  Run a single health check pass. Returns `{checked, stale}` counts.

  Exposed for tests and manual invocation.
  """
  @spec run_check(DateTime.t()) :: {non_neg_integer(), non_neg_integer()}
  def run_check(now \\ DateTime.utc_now()) do
    actor = SystemActor.system(:schedule_health_worker)

    case JobSchedule.list_enabled(actor: actor) do
      {:ok, schedules} ->
        stale = ScheduleHealthCheck.stale_schedules(schedules, now)

        Enum.each(stale, &alert_stale/1)

        :telemetry.execute(
          [:serviceradar, :job_schedule, :health, :run],
          %{checked: length(schedules), stale: length(stale)},
          %{}
        )

        {length(schedules), length(stale)}

      {:error, reason} ->
        Logger.warning("ScheduleHealthWorker: failed to read job schedules: #{inspect(reason)}")

        {0, 0}
    end
  end

  defp alert_stale(entry) do
    Logger.warning(
      "ScheduleHealthWorker: job schedule '#{entry.job_key}' is stale — " <>
        "cron '#{entry.cron}' has not enqueued for #{entry.seconds_since_enqueue}s " <>
        "(threshold #{entry.threshold_seconds}s; last_enqueued_at=#{inspect(entry.last_enqueued_at)}). " <>
        "The scheduler pipeline for this job is broken."
    )

    :telemetry.execute(
      [:serviceradar, :job_schedule, :health, :stale],
      %{
        count: 1,
        seconds_since_enqueue: entry.seconds_since_enqueue,
        interval_seconds: entry.interval_seconds
      },
      %{
        job_key: entry.job_key,
        cron: entry.cron,
        last_enqueued_at: entry.last_enqueued_at
      }
    )
  end

  defp reschedule(config) do
    reschedule_seconds =
      case Keyword.get(config, :reschedule_seconds) do
        value when is_integer(value) and value > 0 -> value
        _ -> @default_reschedule_seconds
      end

    _ = ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 60)))
    :ok
  end

  defp job_already_scheduled? do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end
end
