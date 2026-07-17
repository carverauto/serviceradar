defmodule ServiceRadar.ColdTier.Pruner do
  @moduledoc """
  Cold-window pruning + manifest/bucket reconciliation
  (OpenSpec add-tiered-telemetry-offload, task 2.7; design D9).

  Tombstone-first ordering (spike 0.5: manifest-driven readers hard-error on
  missing keys, so objects must never disappear while a manifest row still
  presents them as readable):

    1. tombstone — verified manifest rows entirely older than the table's
       cold window flip to `pruned` (readers exclude them);
    2. delete — objects for pruned rows are removed from the bucket;
    3. GC — manifest rows whose objects are gone are deleted.

  Reconciliation sweep (owns its own cleanup — bucket lifecycle rules are
  requested at provisioning but never trusted; MinIO silently drops the
  abort-multipart element):

    * unmanifested objects under the cold prefix older than a safety age are
      garbage (a COPY ran but verification never committed) — deleted;
    * verified manifest rows whose objects are MISSING are a data-loss
      signal — alerted loudly, never auto-repaired here;
    * multipart uploads older than the safety age are aborted.

  Inert without deployment-supplied cold-tier configuration.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 3_600, states: :incomplete]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.ColdTier.Config
  alias ServiceRadar.ColdTier.ObjectStore
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.Repo

  require Logger

  @query_timeout_ms 120_000
  @orphan_safety_hours 24

  @impl Oban.Worker
  def perform(_job) do
    if Config.enabled?(), do: run(), else: :ok
  end

  @doc "One full prune + reconcile pass. Public for tests and manual runs."
  @spec run() :: :ok
  def run do
    Enum.each(Registry.tables(), fn entry ->
      tombstone_expired(entry)
      delete_pruned_objects(entry)
      reconcile(entry)
    end)

    abort_stale_multipart_uploads()
    :ok
  end

  # --- phase 1: tombstone ---

  defp tombstone_expired(entry) do
    case Registry.cold_window_days(entry) do
      nil ->
        # No configured window ⇒ no expiry pruning (design D9). Reconciliation
        # (orphans, multipart debris) still runs; archives are kept.
        :ok

      cold_days ->
        do_tombstone_expired(entry, cold_days)
    end
  end

  defp do_tombstone_expired(entry, cold_days) do
    sql = """
    UPDATE platform.cold_chunk_exports
    SET status = 'pruned', pruned_at = now(), updated_at = now()
    WHERE table_name = $1
      AND status = 'verified'
      AND range_end < now() - ($2 * INTERVAL '1 day')
    """

    case SQL.query(Repo, sql, [entry.table, cold_days], timeout: @query_timeout_ms) do
      {:ok, %{num_rows: n}} when n > 0 ->
        Logger.info("Cold tier: tombstoned expired archive chunks",
          table: entry.table,
          chunks: n,
          cold_window_days: cold_days
        )

      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning("Cold tier: tombstone pass failed",
          table: entry.table,
          reason: Exception.message(error)
        )
    end
  end

  # --- phase 2 + 3: delete objects, then GC manifest rows ---

  defp delete_pruned_objects(entry) do
    sql = """
    SELECT id, object_keys FROM platform.cold_chunk_exports
    WHERE table_name = $1 AND status = 'pruned'
    ORDER BY range_start ASC
    LIMIT 500
    """

    case SQL.query(Repo, sql, [entry.table], timeout: @query_timeout_ms) do
      {:ok, %{rows: rows}} when rows != [] ->
        keys = Enum.flat_map(rows, fn [_id, object_keys] -> object_keys end)
        ids = Enum.map(rows, fn [id, _] -> id end)

        case ObjectStore.delete_objects(keys) do
          {:ok, deleted} ->
            SQL.query!(Repo, "DELETE FROM platform.cold_chunk_exports WHERE id = ANY($1)", [ids],
              timeout: @query_timeout_ms
            )

            Logger.info("Cold tier: pruned archive objects",
              table: entry.table,
              objects: deleted,
              manifest_rows: length(ids)
            )

          {:error, reason} ->
            # Objects stay, manifest rows stay 'pruned' (excluded from reads);
            # retried next run.
            Logger.warning("Cold tier: archive object deletion failed; will retry",
              table: entry.table,
              reason: inspect(reason)
            )
        end

      _ ->
        :ok
    end
  end

  # --- reconciliation sweep ---

  defp reconcile(entry) do
    prefix = "cold/#{Registry.layout_version()}/#{entry.table}/"

    with {:ok, objects} <- ObjectStore.list_objects(prefix),
         {:ok, %{rows: rows}} <-
           SQL.query(
             Repo,
             "SELECT unnest(object_keys), status FROM platform.cold_chunk_exports WHERE table_name = $1",
             [entry.table],
             timeout: @query_timeout_ms
           ) do
      manifested = Map.new(rows, fn [key, status] -> {key, status} end)
      cutoff = DateTime.add(DateTime.utc_now(), -@orphan_safety_hours * 3600, :second)

      # Staging objects are never manifested (the manifest records the
      # published key) and are never readable, so a stale one past the safety
      # age is exactly the garbage this sweep should collect — the generic
      # orphan rule below already covers them. Objects listed here are checked
      # against the manifest by key, and `missing` (below) only considers
      # published keys, so staging can never look like lost archive data.
      orphans =
        for %{key: key, last_modified: lm} <- objects,
            not Map.has_key?(manifested, key),
            old_enough?(lm, cutoff),
            do: key

      if orphans != [] do
        case ObjectStore.delete_objects(orphans) do
          {:ok, n} ->
            Logger.info("Cold tier: swept unmanifested archive objects",
              table: entry.table,
              objects: n
            )

          {:error, reason} ->
            Logger.warning("Cold tier: orphan sweep deletion failed",
              table: entry.table,
              reason: inspect(reason)
            )
        end
      end

      object_keys = MapSet.new(objects, & &1.key)

      missing =
        for {key, "verified"} <- manifested, not MapSet.member?(object_keys, key), do: key

      if missing != [] do
        # Demote BEFORE alerting: while the row says `verified` the retention
        # gate treats the range as durable and can drop the still-hot source
        # into a hole. Demoting to `pending` both blocks the gate (the
        # contiguous-verified prefix stops here) and re-queues the chunk for
        # export while the source may still exist.
        demoted =
          case SQL.query(
                 Repo,
                 """
                 UPDATE platform.cold_chunk_exports
                 SET status = 'pending',
                     verified_at = NULL,
                     last_error = 'archive object missing at reconciliation',
                     updated_at = now()
                 WHERE table_name = $1
                   AND status = 'verified'
                   AND object_keys && $2
                 """,
                 [entry.table, missing],
                 timeout: @query_timeout_ms
               ) do
            {:ok, %{num_rows: n}} -> n
            {:error, _} -> 0
          end

        Logger.error(
          "Cold tier: verified manifest rows reference MISSING archive objects — " <>
            "possible external deletion or bucket corruption. Demoted to pending so " <>
            "retention cannot drop the source into a hole and the exporter re-exports " <>
            "while the source exists; ranges whose source is already gone are " <>
            "UNRECOVERABLE and need operator attention (docs/cold-tier-runbook.md)",
          table: entry.table,
          missing_objects: length(missing),
          demoted_manifest_rows: demoted,
          sample: Enum.take(missing, 5)
        )
      end

      :ok
    else
      {:error, reason} ->
        Logger.warning("Cold tier: reconciliation sweep skipped",
          table: entry.table,
          reason: inspect(reason)
        )

      _ ->
        :ok
    end
  end

  defp abort_stale_multipart_uploads do
    cutoff = DateTime.add(DateTime.utc_now(), -@orphan_safety_hours * 3600, :second)

    case ObjectStore.list_multipart_uploads() do
      {:ok, uploads} ->
        for %{key: key, upload_id: upload_id, initiated: initiated} <- uploads,
            old_enough?(initiated, cutoff) do
          case ObjectStore.abort_multipart_upload(key, upload_id) do
            :ok ->
              Logger.info("Cold tier: aborted stale multipart upload", key: key)

            {:error, reason} ->
              Logger.warning("Cold tier: failed to abort multipart upload",
                key: key,
                reason: inspect(reason)
              )
          end
        end

        :ok

      {:error, reason} ->
        Logger.warning("Cold tier: multipart sweep skipped", reason: inspect(reason))
    end
  end

  defp old_enough?(iso8601, cutoff) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _} -> DateTime.before?(dt, cutoff)
      _ -> false
    end
  end
end
