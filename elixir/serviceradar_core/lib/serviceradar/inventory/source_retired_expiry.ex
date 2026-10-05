defmodule ServiceRadar.Inventory.SourceRetiredExpiry do
  @moduledoc """
  Soft-deletes the records marked `source_retired` once their grace period ends (change
  `add-source-id-succession`, design D5; requirement "Retired Records Without A Successor").

  `ServiceRadar.Inventory.Identity.SourceRetirement` marks a record when a retirement leaves it
  holding only retired source ids. The marked record stays live, hidden from the inventory, for
  `source_retired_grace_days` (default 7), so that a succession, a reactivation or a review can
  still reach it. A `ServiceRadar.Inventory.DeviceCleanupWorker` pass then soft-deletes it
  through `Device :soft_delete`, with `deleted_reason: "source_retired"` and
  `deleted_by: "system:source_retirement"`, and the same statement clears its address. The
  tombstone is retained (`Device.retained_reasons/0`): no sweep, discovery poll or check-in
  restores it.

  A record named by an open de-duplication task is held: it is not deleted while the task is
  open, however long ago it was marked. The SQL function `platform.device_held_for_review/1` is
  the one definition of the hold, read by the candidate query and by the delete.

  The mark, the grace period and the hold are checked again in the `UPDATE ... WHERE` that
  soft-deletes, so a record whose mark cleared, or that a task came to name, after it was
  selected is left alone.

  A pass that would delete more than `source_retirement_max_fraction` of the live records is
  refused on the retirement pass's terms (design D1): nothing is deleted, the refusal is logged
  at error level and emitted as `[:serviceradar, :inventory, :source_retired_expiry, :refused]`,
  and `source_retirement_guard_override` admits the next refused pass, which clears it. The pass
  is not scoped to a source instance, so it is judged against every live record. Each pass emits
  its counts as `[:serviceradar, :inventory, :source_retired_expiry, :run]`.

  With `source_retirement_enabled` off, or settings that could not be read, the pass deletes
  nothing: marked records stay hidden until retirement is enabled again.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @deleted_reason "source_retired"
  @deleted_by "system:source_retirement"
  @default_grace_days 7
  @default_max_fraction 0.5
  @default_batch_size 1_000

  @type settings :: %{
          optional(:source_retirement_enabled) => boolean(),
          optional(:source_retired_grace_days) => pos_integer(),
          optional(:source_retirement_max_fraction) => float(),
          optional(:source_retirement_guard_override) => boolean(),
          optional(:batch_size) => pos_integer()
        }

  @type stats :: %{
          deleted: non_neg_integer(),
          candidates: non_neg_integer(),
          held: non_neg_integer()
        }

  @doc "The `deleted_reason` a record deleted at the end of its grace period carries."
  @spec deleted_reason() :: String.t()
  def deleted_reason, do: @deleted_reason

  @doc """
  When a record marked at `marked_at` becomes due for deletion, `grace_days` later. A pass
  deletes it on its first run at or after that time, unless an open de-duplication task holds
  it.
  """
  @spec deletes_after(DateTime.t(), pos_integer()) :: DateTime.t()
  def deletes_after(%DateTime{} = marked_at, grace_days)
      when is_integer(grace_days) and grace_days > 0,
      do: DateTime.shift(marked_at, day: grace_days)

  @doc """
  Whether an open de-duplication task names the device, so that no grace pass deletes it:
  `platform.device_held_for_review/1`, the definition the pass reads.
  """
  @spec held_for_review(String.t()) :: {:ok, boolean()} | {:error, term()}
  def held_for_review(uid) when is_binary(uid) do
    case Repo.query("SELECT platform.device_held_for_review($1)", [uid]) do
      {:ok, %{rows: [[held]]}} -> {:ok, held == true}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs one grace pass. Returns `{:ok, stats}`: `candidates` were past their grace period and
  not held, `deleted` were soft-deleted, and `held` were past their grace period but named by
  an open de-duplication task. Returns `{:error, {:mass_deletion_refused, counts}}`, deleting
  nothing, when the mass guard refuses the pass.

  `opts`:
    * `:now` - the reference time (default `DateTime.utc_now/0`);
    * `:uids` - restrict the pass, and the live records the mass guard counts, to these device
      uids (tests and the DIRE lifecycle trace, which must not delete records outside their own
      world).
  """
  @spec run(settings(), term(), keyword()) :: {:ok, stats()} | {:error, term()}
  def run(settings, actor, opts \\ []) do
    if Map.get(settings, :source_retirement_enabled) == true do
      grace_days = Map.get(settings, :source_retired_grace_days) || @default_grace_days
      now = Keyword.get(opts, :now, DateTime.utc_now())
      cutoff = DateTime.shift(now, day: -grace_days)
      batch_size = Map.get(settings, :batch_size) || @default_batch_size

      with :ok <- mass_deletion_guard(settings, cutoff, opts) do
        held =
          cutoff
          |> due_query(opts)
          |> where([d], fragment("platform.device_held_for_review(?)", d.uid))
          |> count()

        stats = delete_batches(cutoff, batch_size, actor, opts, nil, empty_stats(held))
        emit(stats)
        {:ok, stats}
      end
    else
      {:ok, empty_stats(0)}
    end
  end

  defp empty_stats(held), do: %{deleted: 0, candidates: 0, held: held}

  # Keyset pagination on (source_retired_at, uid): each batch starts after the last record the
  # previous one judged, so a record the delete left alone is never read twice in a pass.
  defp delete_batches(cutoff, batch_size, actor, opts, after_key, stats) do
    candidates = candidates(cutoff, batch_size, after_key, opts)

    deleted =
      case candidates do
        [] -> []
        candidates -> soft_delete(Enum.map(candidates, & &1.uid), cutoff, actor)
      end

    stats = %{
      stats
      | deleted: stats.deleted + length(deleted),
        candidates: stats.candidates + length(candidates)
    }

    if length(candidates) == batch_size do
      last = List.last(candidates)
      delete_batches(cutoff, batch_size, actor, opts, {last.source_retired_at, last.uid}, stats)
    else
      stats
    end
  end

  defp mass_deletion_guard(settings, cutoff, opts) do
    max_fraction = Map.get(settings, :source_retirement_max_fraction) || @default_max_fraction
    candidates = cutoff |> candidate_query(nil, opts) |> count()
    live = live_count(opts)

    case CanonicalRebuild.prune_guard_check(candidates, live, max_fraction, false) do
      :allow ->
        :ok

      {:refuse, reason} ->
        if Map.get(settings, :source_retirement_guard_override) == true and
             SourceRetirement.consume_guard_override() do
          Logger.warning(
            "SourceRetiredExpiry: pass over the guard admitted by " <>
              "source_retirement_guard_override, now cleared: deleting up to #{candidates} " <>
              "of #{live} live records (max fraction #{max_fraction})"
          )

          :ok
        else
          refuse(reason, candidates, live, max_fraction)
        end
    end
  end

  defp refuse(reason, candidates, live, max_fraction) do
    :telemetry.execute(
      [:serviceradar, :inventory, :source_retired_expiry, :refused],
      %{candidates: candidates, live_devices: live},
      %{reason: reason, max_fraction: max_fraction}
    )

    Logger.error(
      "SourceRetiredExpiry: pass refused (#{reason}): would delete up to #{candidates} of " <>
        "#{live} live records in one pass (max fraction #{max_fraction}); set " <>
        "source_retirement_guard_override in the device cleanup settings to admit it"
    )

    {:error,
     {:mass_deletion_refused, %{candidates: candidates, live: live, max_fraction: max_fraction}}}
  end

  defp count(query), do: query |> exclude(:order_by) |> select([d], count()) |> Repo.one()

  defp live_count(opts) do
    from(d in "ocsf_devices", prefix: "platform", where: is_nil(d.deleted_at))
    |> restrict(opts)
    |> count()
  end

  defp candidates(cutoff, batch_size, after_key, opts) do
    cutoff
    |> candidate_query(after_key, opts)
    |> limit(^batch_size)
    |> select([d], %{uid: d.uid, source_retired_at: d.source_retired_at})
    |> Repo.all()
  end

  # Live records past their grace period that no open de-duplication task holds, earliest
  # marked first.
  defp candidate_query(cutoff, after_key, opts) do
    query =
      cutoff
      |> due_query(opts)
      |> where([d], not fragment("platform.device_held_for_review(?)", d.uid))
      |> order_by([d], asc: d.source_retired_at, asc: d.uid)

    case after_key do
      nil ->
        query

      {marked_at, uid} ->
        where(
          query,
          [d],
          fragment("(?, ?) > (?, ?)", d.source_retired_at, d.uid, ^marked_at, ^uid)
        )
    end
  end

  # Live records marked at or before the cutoff, held or not; the partial index on marked live
  # records serves it.
  defp due_query(cutoff, opts) do
    restrict(
      from(d in "ocsf_devices",
        prefix: "platform",
        where: is_nil(d.deleted_at) and not is_nil(d.source_retired_at),
        where: d.source_retired_at <= ^cutoff
      ),
      opts
    )
  end

  defp restrict(query, opts) do
    case Keyword.get(opts, :uids) do
      nil -> query
      uids -> where(query, [d], d.uid in ^uids)
    end
  end

  # The soft delete re-checks liveness, the mark, the grace period and the hold in the UPDATE's
  # WHERE clause, so the decision and the delete are one statement. `ip: nil` releases the
  # address in that statement.
  defp soft_delete(uids, cutoff, actor) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false})
      |> Ash.Query.filter(
        uid in ^uids and is_nil(deleted_at) and not is_nil(source_retired_at) and
          source_retired_at <= ^cutoff and
          not fragment("platform.device_held_for_review(?)", uid)
      )

    result =
      Ash.bulk_update(
        query,
        :soft_delete,
        %{deleted_reason: @deleted_reason, deleted_by: @deleted_by, ip: nil},
        actor: actor,
        strategy: [:atomic],
        return_records?: true,
        return_errors?: true,
        select: [:uid]
      )

    case result do
      %Ash.BulkResult{status: :success, records: records} ->
        deleted = Enum.map(records || [], & &1.uid)
        log_deleted(deleted)
        deleted

      %Ash.BulkResult{errors: errors, records: records} ->
        Logger.warning("SourceRetiredExpiry: soft delete failed", errors: inspect(errors))
        Enum.map(records || [], & &1.uid)
    end
  end

  defp log_deleted([]), do: :ok

  defp log_deleted(uids) do
    Logger.info(
      "SourceRetiredExpiry: soft-deleted #{length(uids)} record(s) marked source_retired " <>
        "past the grace period: #{inspect(Enum.take(uids, 50))}"
    )
  end

  defp emit(stats) do
    :telemetry.execute(
      [:serviceradar, :inventory, :source_retired_expiry, :run],
      %{deleted: stats.deleted, candidates: stats.candidates, held: stats.held},
      %{deleted_reason: @deleted_reason}
    )
  end
end
