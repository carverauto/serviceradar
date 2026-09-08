defmodule ServiceRadarWebNG.Dashboards.ReportScannerWorker do
  @moduledoc """
  Periodic scanner for due authored dashboard email reports.

  This is intentionally one Oban cron job for all dashboard schedules. Each due
  schedule produces an idempotent delivery row and one delivery worker job.
  """

  use Oban.Worker,
    queue: :web_maintenance,
    max_attempts: 3,
    unique: [period: 55, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.DashboardReportDelivery
  alias ServiceRadar.Dashboards.DashboardReportSchedule
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadarWebNG.Dashboards.Authored
  alias ServiceRadarWebNG.Dashboards.ReportDeliveryWorker

  require Ash.Query
  require Logger

  @default_limit 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if enabled?(args) do
      scan_due_schedules(limit_arg(args))
    else
      Logger.debug("Dashboard report scanner skipped because scheduled reports are disabled")
      :ok
    end
  end

  @spec enqueue_now(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_now(opts \\ []) do
    args = maybe_put(%{"enabled" => true, "manual" => true}, "limit", Keyword.get(opts, :limit))

    args
    |> new()
    |> ObanSupport.safe_insert()
  end

  defp scan_due_schedules(limit) do
    actor = system_actor()

    case due_schedules(actor, limit) do
      {:ok, schedules} ->
        summary =
          Enum.reduce(schedules, %{queued: 0, failed: 0}, fn schedule, acc ->
            case enqueue_delivery(actor, schedule) do
              {:ok, _delivery} -> %{acc | queued: acc.queued + 1}
              {:error, reason} -> record_scan_failure(actor, schedule, reason, acc)
            end
          end)

        Logger.info("Dashboard report scanner completed: queued=#{summary.queued} failed=#{summary.failed}")

        :ok

      {:error, reason} ->
        Logger.warning("Dashboard report scanner failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp due_schedules(actor, limit) do
    DashboardReportSchedule
    |> Ash.Query.for_read(:due)
    |> Ash.Query.sort(next_due_at: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read(actor: actor)
  end

  defp enqueue_delivery(actor, schedule) do
    due_at = schedule.next_due_at || DateTime.utc_now()
    next_due_at = next_due_at(schedule, due_at)

    case Repo.transaction(fn ->
           with {:ok, delivery, delivery_notifications} <- create_delivery(actor, schedule, due_at),
                {:ok, _schedule, schedule_notifications} <- record_due_enqueue(actor, schedule, due_at, next_due_at),
                {:ok, _job} <- ensure_delivery_job(delivery) do
             {delivery, delivery_notifications ++ schedule_notifications}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {delivery, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, delivery}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_delivery(actor, schedule, due_at) do
    attrs = %{
      schedule_id: schedule.id,
      dashboard_id: schedule.dashboard_id,
      due_at: due_at,
      status: :pending,
      recipients: schedule.recipients || [],
      recipient_count: length(schedule.recipients || []),
      rendered_metadata: %{}
    }

    DashboardReportDelivery
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create(actor: actor, return_notifications?: true)
  end

  defp record_due_enqueue(actor, schedule, due_at, next_due_at) do
    schedule
    |> Ash.Changeset.for_update(
      :record_due_enqueue,
      %{due_at: due_at, next_due_at: next_due_at},
      actor: actor
    )
    |> Ash.update(actor: actor, return_notifications?: true)
  end

  defp ensure_delivery_job(%{status: status}) when status in [:sent, "sent"] do
    {:ok, :already_sent}
  end

  defp ensure_delivery_job(delivery) do
    %{"delivery_id" => delivery.id}
    |> ReportDeliveryWorker.new()
    |> ObanSupport.safe_insert()
  end

  defp record_scan_failure(actor, schedule, reason, acc) do
    _ =
      schedule
      |> Ash.Changeset.for_update(:record_failure, %{last_error: inspect(reason)}, actor: actor)
      |> Ash.update(actor: actor)

    Logger.warning("Dashboard report schedule enqueue failed",
      schedule_id: schedule.id,
      reason: inspect(reason)
    )

    %{acc | failed: acc.failed + 1}
  end

  defp next_due_at(schedule, due_at) do
    Authored.next_due_at(
      schedule.cron,
      schedule.timezone || "UTC",
      DateTime.add(due_at, 1, :second)
    )
  end

  defp system_actor, do: SystemActor.system(:dashboard_report_scanner)

  defp enabled?(args), do: bool_arg(args, "enabled", config(:enabled?, true))

  defp limit_arg(args) do
    args
    |> Map.get("limit")
    |> positive_integer(config(:scanner_limit, @default_limit))
  end

  defp config(key, default) do
    :serviceradar_web_ng
    |> Application.get_env(:dashboard_reports, [])
    |> Keyword.get(key, default)
  end

  defp bool_arg(args, key, default) do
    case Map.get(args || %{}, key) do
      value when value in [true, "true", "1", 1, "yes"] -> true
      value when value in [false, "false", "0", 0, "no"] -> false
      _ -> default
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
