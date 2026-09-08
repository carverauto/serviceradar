defmodule ServiceRadar.Inventory.DeviceCleanupWorker do
  @moduledoc """
  Oban worker that purges soft-deleted devices after a retention period.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Repo
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
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
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

    Repo.exists?(query, prefix: ObanSupport.prefix())
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

    case ObanSupport.safe_insert(
           SelfScheduling.successor_changeset(__MODULE__, %{"scheduled" => true}, schedule_in)
         ) do
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
      |> Ash.Query.filter(
        not is_nil(deleted_at) and deleted_at < ^cutoff and
          (is_nil(deleted_reason) or deleted_reason != "armis_source_device_id_ghost_cleanup")
      )
      |> Ash.Query.limit(batch_size)

    case Page.unwrap(Ash.read(query, actor: actor)) do
      {:ok, []} ->
        stats

      {:ok, records} ->
        {updated, deleted_count} = hard_delete_records(stats, records)

        if deleted_count > 0 do
          do_purge(cutoff, batch_size, actor, updated)
        else
          updated
        end

      {:error, reason} ->
        Logger.warning("DeviceCleanupWorker: failed to read cleanup batch",
          reason: inspect(reason)
        )

        %{stats | errors: stats.errors + 1}
    end
  end

  # Child tables that carry a NO ACTION / RESTRICT FK to ocsf_devices.uid and
  # must be deleted BEFORE the parent device, paired with their FK column.
  # SET NULL / CASCADE children (virtualization_*, device_agent_availability)
  # are handled automatically by the parent delete and are not listed here.
  @fk_children [
    {"device_identifiers", :device_id},
    {"device_alias_states", :device_id},
    {"discovered_interfaces", :device_id},
    {"ocsf_agents", :device_uid},
    {"service_checks", :device_uid},
    {"device_snmp_credentials", :device_id},
    {"alerts", :device_uid},
    {"device_fleet_ordinals", :uid}
  ]

  # Hard-delete a batch of soft-deleted devices FK-safely. The previous
  # implementation ran `delete_all` on ocsf_devices ALONE, hit the FK from 10+
  # child tables, rescued the violation and reported `deleted: 0` — silently
  # no-opping forever. This deletes every NO ACTION/RESTRICT child before the
  # parent, in ONE transaction per batch, so the parent delete cannot
  # FK-violate. To close the read->delete race (uids are read outside the
  # transaction in do_purge), the still-tombstoned uids are re-selected
  # FOR UPDATE inside the transaction and ONLY those are purged — so a
  # concurrent restore/gateway_sync that clears deleted_at in the gap can never
  # have its now-LIVE device's child identity rows wiped.
  defp hard_delete_records(stats, records) do
    uids = Enum.map(records, & &1.uid)

    fn ->
      # Re-check + lock the still-tombstoned devices INSIDE the transaction.
      # FOR UPDATE blocks a racing restore until we commit; a restore that
      # already committed drops the uid from this set (deleted_at IS NULL). Only
      # the locked, still-deleted uids are purged (children first, then parent).
      locked_uids =
        Repo.all(
          from(d in "ocsf_devices",
            where: d.uid in ^uids and not is_nil(d.deleted_at),
            select: d.uid,
            lock: "FOR UPDATE"
          ),
          prefix: "platform"
        )

      if locked_uids == [] do
        0
      else
        Enum.each(@fk_children, fn {table, fk_column} ->
          Repo.delete_all(
            from(c in table, where: field(c, ^fk_column) in ^locked_uids),
            prefix: "platform"
          )
        end)

        {deleted_count, _} =
          Repo.delete_all(
            from(d in "ocsf_devices", where: d.uid in ^locked_uids),
            prefix: "platform"
          )

        deleted_count
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, deleted_count} ->
        {%{stats | deleted: stats.deleted + deleted_count}, deleted_count}

      {:error, reason} ->
        Logger.warning("DeviceCleanupWorker: delete failures", error: inspect(reason))
        {%{stats | errors: stats.errors + 1}, 0}
    end
  rescue
    error ->
      Logger.warning("DeviceCleanupWorker: delete failures", error: inspect(error))
      {%{stats | errors: stats.errors + 1}, 0}
  end
end
