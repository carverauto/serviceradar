defmodule ServiceRadar.Inventory.DeviceCleanupWorker do
  @moduledoc """
  Oban worker that purges soft-deleted devices after a retention period.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.{Device, DeviceCleanupSettings}
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_retention_days 30
  @default_cleanup_interval_minutes 1_440
  @default_batch_size 1_000

  @doc """
  Ensure the cleanup job is scheduled based on current settings.
  """
  @spec ensure_scheduled() ::
          {:ok, Oban.Job.t() | :already_scheduled | :disabled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      case check_existing_job() do
        true ->
          {:ok, :already_scheduled}

        false ->
          schedule_from_settings()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @doc """
  Enqueue an immediate cleanup run (manual trigger).
  """
  @spec enqueue_manual(term()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_manual(_actor \\ nil) do
    if ObanSupport.available?() do
      %{"manual" => true}
      |> new()
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    manual? = Map.get(args, "manual", false)
    actor = SystemActor.system(:device_cleanup_worker)

    settings = load_settings(actor)

    if not settings.enabled and not manual? do
      Logger.info("DeviceCleanupWorker: cleanup disabled, skipping")
      :ok
    else
      retention_days = settings.retention_days
      batch_size = settings.batch_size
      cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

      Logger.info(
        "DeviceCleanupWorker: Starting cleanup - deleted devices older than #{retention_days} days"
      )

      stats = purge_deleted_devices(cutoff, batch_size, actor)

      Logger.info("DeviceCleanupWorker: Completed cleanup",
        deleted: stats.deleted,
        errors: stats.errors
      )

      if settings.enabled do
        schedule_next(settings.cleanup_interval_minutes)
      end

      :ok
    end
  end

  defp check_existing_job do
    import Ecto.Query

    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp schedule_from_settings do
    settings = load_settings(SystemActor.system(:device_cleanup_scheduler))

    if settings.enabled do
      schedule_next(settings.cleanup_interval_minutes)
    else
      {:ok, :disabled}
    end
  end

  defp schedule_next(interval_minutes) do
    schedule_in = max(interval_minutes, 1) * 60

    case ObanSupport.safe_insert(new(%{"scheduled" => true}, schedule_in: schedule_in)) do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_settings(actor) do
    case DeviceCleanupSettings.get_settings(actor: actor) do
      {:ok, %DeviceCleanupSettings{} = settings} ->
        settings

      _ ->
        %DeviceCleanupSettings{
          retention_days: @default_retention_days,
          cleanup_interval_minutes: @default_cleanup_interval_minutes,
          batch_size: @default_batch_size,
          enabled: true
        }
    end
  end

  defp purge_deleted_devices(cutoff, batch_size, actor) do
    do_purge(cutoff, batch_size, actor, %{deleted: 0, errors: 0})
  end

  defp do_purge(cutoff, batch_size, actor, stats) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(not is_nil(deleted_at) and deleted_at < ^cutoff)
      |> Ash.Query.limit(batch_size)

    case Page.unwrap(Ash.read(query, actor: actor)) do
      {:ok, []} ->
        stats

      {:ok, records} ->
        result =
          Ash.bulk_destroy(records, :destroy, %{},
            actor: actor,
            return_records?: false,
            return_errors?: true
          )

        updated = accumulate_bulk_result(stats, result, length(records))
        do_purge(cutoff, batch_size, actor, updated)

      {:error, reason} ->
        Logger.warning("DeviceCleanupWorker: failed to read cleanup batch",
          reason: inspect(reason)
        )

        %{stats | errors: stats.errors + 1}
    end
  end

  defp accumulate_bulk_result(
         stats,
         %Ash.BulkResult{status: :success, error_count: error_count},
         batch_count
       ) do
    deleted = max(batch_count - error_count, 0)
    %{stats | deleted: stats.deleted + deleted, errors: stats.errors + error_count}
  end

  defp accumulate_bulk_result(
         stats,
         %Ash.BulkResult{status: :partial_success, errors: errors, error_count: error_count},
         batch_count
       ) do
    deleted = max(batch_count - error_count, 0)
    Logger.warning("DeviceCleanupWorker: partial delete failures", errors: inspect(errors))
    %{stats | deleted: stats.deleted + deleted, errors: stats.errors + error_count}
  end

  defp accumulate_bulk_result(
         stats,
         %Ash.BulkResult{status: :error, errors: errors, error_count: error_count},
         _batch_count
       ) do
    Logger.warning("DeviceCleanupWorker: delete failures", errors: inspect(errors))
    %{stats | errors: stats.errors + max(error_count, length(errors || []))}
  end

  defp accumulate_bulk_result(stats, other, _batch_count) do
    Logger.warning("DeviceCleanupWorker: unexpected bulk result", result: inspect(other))
    %{stats | errors: stats.errors + 1}
  end
end
