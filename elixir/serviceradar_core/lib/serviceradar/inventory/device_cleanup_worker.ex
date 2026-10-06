defmodule ServiceRadar.Inventory.DeviceCleanupWorker do
  @moduledoc """
  Oban worker for device lifecycle cleanup. Each run:

    1. expires ephemeral devices -- no strong identifier, unseen past the configured window --
       by soft-deleting them with `deleted_reason: "stale_ephemeral"`
       (`ServiceRadar.Inventory.EphemeralDeviceExpiry`);
    2. soft-deletes the records marked `source_retired` whose grace period ended, with
       `deleted_reason: "source_retired"` (`ServiceRadar.Inventory.SourceRetiredExpiry`);
    3. purges soft-deleted devices after the retention period.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.EphemeralDeviceExpiry
  alias ServiceRadar.Inventory.SourceRetiredExpiry
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_retention_days 30
  @default_cleanup_interval_minutes 1_440
  @default_batch_size 1_000
  @default_ephemeral_expiry_days 30

  # Upper bound on purge batches per run; the rest resumes on the next run.
  @max_purge_batches_per_run 100

  # How deep the purge follows blocking foreign keys below ocsf_devices
  # (devices -> agents -> checkers is depth 2).
  @max_fk_depth 4

  # Automation audit and quarantine history keyed to a device. These RESTRICT
  # the device delete on purpose: a device they reference is skipped by the
  # purge rather than stripped of that history.
  @retained_children [
    "platform.ansible_automation_execution_targets",
    "platform.ansible_automation_target_holds"
  ]

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

    if manual?, do: Logger.info("DeviceCleanupWorker: manual run triggered by operator")

    settings = load_settings(actor)

    if not settings.enabled and not manual? do
      Logger.info("DeviceCleanupWorker: cleanup disabled, skipping")
      :ok
    else
      retention_days = settings.retention_days
      batch_size = settings.batch_size
      cutoff = DateTime.shift(DateTime.utc_now(), day: -retention_days)

      expire_ephemeral_devices(settings, actor)
      delete_source_retired(settings, actor)

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

  # Runs before the purge; a device expired here is only purged after the retention window,
  # so it stays restorable until then. A failed expiry pass does not stop the purge.
  defp expire_ephemeral_devices(settings, actor) do
    case EphemeralDeviceExpiry.run(Map.from_struct(settings), actor) do
      {:ok, counts} ->
        Logger.info("DeviceCleanupWorker: ephemeral expiry pass complete",
          candidates: counts.candidates,
          kept_by_evidence: counts.kept_by_evidence,
          kept_by_exclusion: counts.kept_by_exclusion,
          eligible: counts.eligible,
          expired: counts.expired,
          skipped_at_delete: counts.skipped_at_delete
        )

      {:error, reason} ->
        Logger.warning("DeviceCleanupWorker: ephemeral expiry skipped", reason: inspect(reason))
    end
  rescue
    error ->
      :telemetry.execute([:serviceradar, :inventory, :ephemeral_expiry, :failed], %{count: 1}, %{
        error: error.__struct__
      })

      Logger.error("DeviceCleanupWorker: ephemeral expiry raised",
        error: Exception.message(error)
      )
  end

  # Runs before the purge for the same reasons as the expiry pass.
  defp delete_source_retired(settings, actor) do
    case SourceRetiredExpiry.run(Map.from_struct(settings), actor) do
      {:ok, %{deleted: deleted, candidates: candidates, held: held}} ->
        Logger.info("DeviceCleanupWorker: source-retired grace pass complete",
          deleted: deleted,
          candidates: candidates,
          held: held
        )

      {:error, reason} ->
        Logger.warning("DeviceCleanupWorker: source-retired grace pass skipped",
          reason: inspect(reason)
        )
    end
  rescue
    error ->
      :telemetry.execute(
        [:serviceradar, :inventory, :source_retired_expiry, :failed],
        %{count: 1},
        %{error: error.__struct__}
      )

      Logger.error("DeviceCleanupWorker: source-retired grace pass raised",
        error: Exception.message(error)
      )
  end

  defp check_existing_job do
    import Ecto.Query

    query =
      from(j in Oban.Job,
        where: j.worker == ^Oban.Worker.to_string(__MODULE__),
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
          enabled: true,
          ephemeral_expiry_enabled: false,
          ephemeral_expiry_days: @default_ephemeral_expiry_days,
          ephemeral_expiry_exclusion_query: nil,
          ephemeral_expiry_max_fraction: 0.5,
          ephemeral_expiry_guard_override: false,
          # Fails closed, as the retirement pass does: settings that cannot be read delete
          # nothing at the end of a grace period.
          source_retirement_enabled: false
        }
    end
  end

  defp purge_deleted_devices(cutoff, batch_size, _actor) do
    do_purge(cutoff, batch_size, nil, @max_purge_batches_per_run, %{
      deleted: 0,
      errors: 0,
      skipped: 0
    })
  end

  # Walks expired tombstones in uid order. A batch that purges nothing (every
  # device skipped or failing) no longer ends the run: the next batch starts
  # after it, so one unpurgeable device cannot hold back every tombstone behind
  # it. The per-run cap bounds the work one run can do.
  defp do_purge(_cutoff, _batch_size, _after_uid, 0, stats) do
    Logger.info("DeviceCleanupWorker: purge batch cap reached; resuming next run",
      max_batches: @max_purge_batches_per_run
    )

    stats
  end

  defp do_purge(cutoff, batch_size, after_uid, batches_left, stats) do
    case purge_candidates(cutoff, batch_size, after_uid) do
      {:ok, []} ->
        stats

      {:ok, uids} ->
        {updated, _deleted_count} = hard_delete_records(stats, Enum.map(uids, &%{uid: &1}))

        if length(uids) < batch_size do
          updated
        else
          do_purge(cutoff, batch_size, List.last(uids), batches_left - 1, updated)
        end

      {:error, reason} ->
        Logger.warning("DeviceCleanupWorker: failed to read cleanup batch",
          reason: inspect(reason)
        )

        %{stats | errors: stats.errors + 1}
    end
  end

  defp purge_candidates(cutoff, batch_size, after_uid) do
    query =
      from(d in "ocsf_devices",
        where: not is_nil(d.deleted_at) and d.deleted_at < ^cutoff,
        where:
          is_nil(d.deleted_reason) or
            d.deleted_reason != "armis_source_device_id_ghost_cleanup",
        order_by: [asc: d.uid],
        limit: ^batch_size,
        select: d.uid
      )

    query = if after_uid, do: from(d in query, where: d.uid > ^after_uid), else: query

    {:ok, Repo.all(query, prefix: "platform")}
  rescue
    error -> {:error, error}
  end

  # Hard-delete a batch of soft-deleted devices FK-safely, in ONE transaction
  # per batch: every row that blocks the parent delete (a NO ACTION / RESTRICT
  # foreign key to ocsf_devices, or to a row being deleted with it, such as an
  # ocsf_agents row's checkers) is deleted first, deepest first. The blocking
  # tables are read from pg_constraint on every call (`purge_plan/0`), so a new
  # foreign key to a device cannot silently stall the purge again: a hard-coded
  # list here once missed three tables, the transaction raised on any batch
  # holding one of their rows, and the same batch was retried and failed on
  # every run.
  #
  # The tables in @retained_children hold automation audit and quarantine
  # records that must outlive the device; a device referenced from one is
  # skipped and logged with the constraint, never stripped of that history.
  # When a batch still fails it is split in halves and each half retried, down
  # to single devices, so only a failing device is left behind, logged with
  # the violated constraint.
  #
  # To close the read->delete race (uids are read outside the transaction), the
  # still-tombstoned uids are re-selected FOR UPDATE inside the transaction and
  # ONLY those are purged -- so a concurrent restore/gateway_sync that clears
  # deleted_at in the gap can never have its now-LIVE device's child rows wiped.
  #
  # Public (@doc false) so the DIRE lifecycle trace can purge exactly the devices it
  # created; running the worker would purge every expired tombstone in the database.
  @doc false
  def hard_delete_records(stats, records) do
    hard_delete_uids(Map.put_new(stats, :skipped, 0), Enum.map(records, & &1.uid), purge_plan())
  rescue
    error ->
      Logger.warning("DeviceCleanupWorker: delete failures", error: describe_error(error))
      {%{stats | errors: stats.errors + 1}, 0}
  end

  defp hard_delete_uids(stats, uids, plan) do
    case purge_batch(uids, plan) do
      {:ok, deleted_count, skipped} ->
        log_skipped(skipped)

        {%{
           stats
           | deleted: stats.deleted + deleted_count,
             skipped: stats.skipped + length(skipped)
         }, deleted_count}

      {:error, error} when length(uids) > 1 ->
        Logger.warning("DeviceCleanupWorker: purge batch failed; splitting it",
          batch_size: length(uids),
          error: describe_error(error)
        )

        # Bisect: one failing device costs about 2*log2(batch) transactions,
        # not one per device, and a batch that failed only for its size (a
        # statement timeout) is retried in smaller pieces.
        {left, right} = Enum.split(uids, div(length(uids), 2))
        {stats, left_deleted} = hard_delete_uids(stats, left, plan)
        {stats, right_deleted} = hard_delete_uids(stats, right, plan)
        {stats, left_deleted + right_deleted}

      {:error, error} ->
        Logger.warning("DeviceCleanupWorker: device purge failed",
          device_uid: List.first(uids),
          constraint: error_constraint(error),
          error: describe_error(error)
        )

        {%{stats | errors: stats.errors + 1}, 0}
    end
  end

  defp purge_batch(uids, plan) do
    fn ->
      # Re-check + lock the still-tombstoned devices INSIDE the transaction.
      # FOR UPDATE blocks a racing restore until we commit; a restore that
      # already committed drops the uid from this set (deleted_at IS NULL).
      locked_uids =
        Repo.all(
          from(d in "ocsf_devices",
            where: d.uid in ^uids and not is_nil(d.deleted_at),
            select: d.uid,
            lock: "FOR UPDATE"
          ),
          prefix: "platform"
        )

      skipped = retained_uids(locked_uids, plan.retained)
      skipped_uids = MapSet.new(skipped, fn {uid, _constraint} -> uid end)
      purge_uids = Enum.reject(locked_uids, &MapSet.member?(skipped_uids, &1))

      if purge_uids == [] do
        {0, skipped}
      else
        Enum.each(plan.deletes, fn {table, predicate} ->
          Repo.query!("DELETE FROM #{table} WHERE #{predicate}", [purge_uids])
        end)

        {deleted_count, _} =
          Repo.delete_all(
            from(d in "ocsf_devices", where: d.uid in ^purge_uids),
            prefix: "platform"
          )

        {deleted_count, skipped}
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, {deleted_count, skipped}} -> {:ok, deleted_count, skipped}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  # Devices among `uids` referenced from a retained table, with the constraint.
  defp retained_uids([], _retained), do: []

  defp retained_uids(uids, retained) do
    Enum.flat_map(retained, fn %{table: table, column: column, constraint: constraint} ->
      %{rows: rows} =
        Repo.query!(
          "SELECT DISTINCT #{column} FROM #{table} WHERE #{column} = ANY($1)",
          [uids]
        )

      Enum.map(rows, fn [uid] -> {uid, constraint} end)
    end)
  end

  defp log_skipped([]), do: :ok

  defp log_skipped(skipped) do
    skipped
    |> Enum.group_by(fn {_uid, constraint} -> constraint end, fn {uid, _} -> uid end)
    |> Enum.each(fn {constraint, uids} ->
      Logger.info("DeviceCleanupWorker: purge skipped devices with retained history",
        constraint: constraint,
        count: length(uids),
        device_uids: Enum.take(uids, 20)
      )
    end)
  end

  @doc false
  # The delete plan for a purge, derived from the catalog:
  #
  #   * `deletes` -- `{table, predicate}` pairs, deepest first, for every table
  #     whose rows would block deleting the selected devices. `$1` in the
  #     predicate is the uid array.
  #   * `retained` -- the direct device foreign keys from @retained_children.
  #
  # CASCADE and SET NULL children are left to the parent delete.
  @spec purge_plan() :: %{deletes: [{String.t(), String.t()}], retained: [map()]}
  def purge_plan do
    edges = blocking_foreign_keys()

    {retained, followed} =
      Enum.split_with(edges, &(&1.child_unquoted in @retained_children))

    deletes =
      collect_deletes(followed, "platform.ocsf_devices", "uid = ANY($1)", MapSet.new(), 0)

    retained =
      retained
      |> Enum.filter(&(&1.parent == "platform.ocsf_devices" and &1.parent_column == "uid"))
      |> Enum.map(&%{table: &1.child, column: &1.column, constraint: &1.constraint})

    %{deletes: deletes, retained: retained}
  end

  # Post-order walk from `parent`: a child's own blockers are deleted before it.
  defp collect_deletes(_edges, _parent, _predicate, _seen, depth) when depth >= @max_fk_depth,
    do: []

  defp collect_deletes(edges, parent, predicate, seen, depth) do
    seen = MapSet.put(seen, parent)

    edges
    |> Enum.filter(&(&1.parent == parent and not MapSet.member?(seen, &1.child)))
    |> Enum.flat_map(fn edge ->
      alias_name = "p#{depth}"

      # `predicate` names the parent's columns unqualified, which resolve to
      # the innermost FROM: the parent table here.
      child_predicate =
        "#{edge.column} IN (SELECT #{alias_name}.#{edge.parent_column} " <>
          "FROM #{parent} #{alias_name} WHERE #{predicate})"

      collect_deletes(edges, edge.child, child_predicate, seen, depth + 1) ++
        [{edge.child, child_predicate}]
    end)
  end

  # Single-column NO ACTION / RESTRICT foreign keys between platform tables, as
  # %{child, column, parent, parent_column, constraint} with schema-qualified,
  # quoted table names.
  defp blocking_foreign_keys do
    %{rows: rows} =
      Repo.query!("""
      SELECT format('%I.%I', cn.nspname, cc.relname),
             quote_ident(ca.attname),
             format('%I.%I', pn.nspname, pc.relname),
             quote_ident(pa.attname),
             c.conname,
             cn.nspname || '.' || cc.relname
      FROM pg_constraint c
      JOIN pg_class cc ON cc.oid = c.conrelid
      JOIN pg_namespace cn ON cn.oid = cc.relnamespace
      JOIN pg_class pc ON pc.oid = c.confrelid
      JOIN pg_namespace pn ON pn.oid = pc.relnamespace
      JOIN pg_attribute ca ON ca.attrelid = c.conrelid AND ca.attnum = c.conkey[1]
      JOIN pg_attribute pa ON pa.attrelid = c.confrelid AND pa.attnum = c.confkey[1]
      WHERE c.contype = 'f'
        AND c.confdeltype IN ('a', 'r')
        AND cardinality(c.conkey) = 1
        AND pn.nspname = 'platform'
      ORDER BY 1, 2, 5
      """)

    Enum.map(rows, fn [child, column, parent, parent_column, constraint, child_unquoted] ->
      %{
        child: child,
        child_unquoted: child_unquoted,
        column: column,
        parent: parent,
        parent_column: parent_column,
        constraint: constraint
      }
    end)
  end

  defp error_constraint(%Postgrex.Error{postgres: %{constraint: constraint}}), do: constraint
  defp error_constraint(_error), do: nil

  defp describe_error(%{__exception__: true} = error), do: Exception.message(error)
  defp describe_error(error), do: inspect(error)
end
