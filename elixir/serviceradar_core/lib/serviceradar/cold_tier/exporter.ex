defmodule ServiceRadar.ColdTier.Exporter do
  @moduledoc """
  Chunk export pipeline for the tiered telemetry cold path
  (OpenSpec add-tiered-telemetry-offload, tasks 2.2/2.3/2.6-partial).

  Per run, for every registry table on a cold-configured deployment:

    1. assert head setup (FDW server/mapping/foreign tables, S3 secret,
       boundary-ack table) and that no in-DB retention policy has reappeared
       on fenced tables (alert if so);
    2. enumerate export-eligible chunks (range_end older than the export
       lag), oldest first, bounded by the per-run budget (paced backfill);
    3. export each chunk with a fresh, discard-after-use head session
       (spike 0.3: COPY is non-preemptible and errored sessions are
       poisoned — never reuse, never cancel), to a deterministic object key
       (idempotent overwrite);
    4. verify with the engine-stable pair (`ServiceRadar.ColdTier.Verification`)
       computed on BOTH the primary and the parquet object — object
       existence proves nothing (spikes 0.3/0.4) — and only then mark the
       manifest row `verified`;
    5. quarantine chunks that keep failing (skip-and-alert; blocks frontier
       advance by construction);
    6. advance the frontier over the contiguous verified prefix, ack the
       query boundary B on the HEAD first, and only then record it on the
       primary — the retention fence only drops below the primary-recorded,
       head-acked B (invariant: drop point <= B <= F).

  Inert without deployment-supplied configuration.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 1_800, states: :incomplete]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.ColdTier.ChunkExport
  alias ServiceRadar.ColdTier.Config
  alias ServiceRadar.ColdTier.Head
  alias ServiceRadar.ColdTier.Health
  alias ServiceRadar.ColdTier.ObjectStore
  alias ServiceRadar.ColdTier.PressureMonitor
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.ColdTier.RetentionFence
  alias ServiceRadar.ColdTier.Verification
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @query_timeout_ms 120_000

  @impl Oban.Worker
  def perform(_job) do
    if Config.enabled?() do
      run()
    else
      :ok
    end
  end

  @doc "One full exporter pass. Public for tests and manual runs."
  @spec run() :: :ok
  def run do
    case Head.session(&Head.ensure_setup/1) do
      {:ok, :ok} ->
        enforce_fence()
        pressure = PressureMonitor.check()
        budget = Config.run_chunk_budget()

        _remaining_budget =
          Enum.reduce(Registry.tables(), budget, fn entry, remaining ->
            exported = export_table(entry, remaining)
            refreshed = predrop_reverify(entry, remaining - exported)
            advance_frontier(entry)
            remaining - exported - refreshed
          end)

        # Health checks run AFTER the pass so quarantine/frontier state
        # reflects this run (task 3.3).
        Health.record_all(pressure)

        :ok

      {:error, reason} ->
        # A down/unreachable head is exactly when the primary is at risk (data
        # can no longer be offloaded), so this branch MUST report health and
        # pressure, not silently return healthy (review F10). Pressure is
        # computed against the primary and does not need the head.
        Logger.error("Cold tier: analytics head setup failed; skipping export run",
          reason: inspect(reason)
        )

        pressure = PressureMonitor.check()
        Health.record_head_failure(reason, pressure)

        :ok
    end
  end

  # --- export ---

  defp export_table(_entry, remaining) when remaining <= 0, do: 0

  defp export_table(entry, remaining) do
    entry
    |> eligible_chunks(remaining)
    |> Enum.reduce(0, fn chunk, count ->
      case export_chunk(entry, chunk) do
        :ok -> count + 1
        :quarantined -> count
        :error -> count
      end
    end)
  end

  # --- pre-drop re-verification (design D4; tasks 2.3/2.5 remainder) ---
  #
  # Timescale chunks are never closed: late-arriving rows and upserts mutate
  # already-exported chunks. For verified chunks approaching their drop point
  # (within the pre-drop window), re-check the primary row count against the
  # manifest and re-export on drift. Update-prone tables (ocsf_events —
  # ON CONFLICT DO UPDATE leaves counts unchanged) are re-exported
  # unconditionally, throttled to once per @update_prone_reexport_interval.
  @predrop_window_hours 26
  # Kept tighter than RetentionFence's update-prone freshness gate
  # (@update_prone_freshness_hours) so a near-drop update-prone chunk is always
  # re-exported recently enough to be droppable (review F03).
  @update_prone_reexport_interval_hours 2

  defp predrop_reverify(_entry, remaining) when remaining <= 0, do: 0

  defp predrop_reverify(entry, remaining) do
    horizon_hours = max(Registry.hot_retention_days(entry) * 24 - @predrop_window_hours, 0)

    sql = """
    SELECT c.chunk_name, c.range_start, c.range_end, m.attempts, m.row_count, m.exported_at
    FROM timescaledb_information.chunks c
    JOIN platform.cold_chunk_exports m
      ON m.table_name = $1 AND m.chunk_name = c.chunk_name AND m.status = 'verified'
    WHERE c.hypertable_schema = 'platform'
      AND c.hypertable_name = $1
      AND c.range_end < now() - ($2 * INTERVAL '1 hour')
    ORDER BY c.range_start ASC
    LIMIT $3
    """

    case SQL.query(Repo, sql, [entry.table, horizon_hours, remaining], timeout: @query_timeout_ms) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, 0, fn [
                                  chunk_name,
                                  range_start,
                                  range_end,
                                  attempts,
                                  row_count,
                                  exported_at
                                ],
                                count ->
          chunk = %{
            chunk_name: chunk_name,
            range_start: range_start,
            range_end: range_end,
            attempts: attempts || 0,
            row_count: row_count
          }

          if needs_reexport?(entry, chunk, exported_at) do
            case attempt_export(entry, chunk) do
              :ok -> count + 1
              _ -> count
            end
          else
            count
          end
        end)

      {:error, error} ->
        Logger.warning("Cold tier: pre-drop re-verification enumeration failed",
          table: entry.table,
          reason: Exception.message(error)
        )

        0
    end
  end

  defp needs_reexport?(%{update_prone: true}, _chunk, exported_at) do
    # Upserts don't change counts — re-export unconditionally, throttled.
    is_nil(exported_at) or
      DateTime.diff(DateTime.utc_now(), exported_at, :hour) >=
        @update_prone_reexport_interval_hours
  end

  defp needs_reexport?(entry, chunk, _exported_at) do
    time = ~s("#{entry.time_column}")

    sql = """
    SELECT count(*)::bigint FROM #{Registry.qualified_table(entry)}
    WHERE #{time} >= $1 AND #{time} < $2
    """

    case SQL.query(Repo, sql, [chunk.range_start, chunk.range_end], timeout: @query_timeout_ms) do
      {:ok, %{rows: [[live_count]]}} ->
        drifted = live_count != chunk.row_count

        if drifted do
          Logger.info("Cold tier: late-write drift detected; re-exporting chunk",
            table: entry.table,
            chunk: chunk.chunk_name,
            manifest_rows: chunk.row_count,
            live_rows: live_count
          )
        end

        drifted

      {:error, _} ->
        false
    end
  end

  defp eligible_chunks(entry, limit) do
    sql = """
    SELECT c.chunk_name, c.range_start, c.range_end,
           m.status, m.attempts, m.row_count
    FROM timescaledb_information.chunks c
    LEFT JOIN platform.cold_chunk_exports m
      ON m.table_name = $1 AND m.chunk_name = c.chunk_name
    WHERE c.hypertable_schema = 'platform'
      AND c.hypertable_name = $1
      AND c.range_end < now() - ($2 * INTERVAL '1 hour')
      AND (m.status IS NULL OR m.status IN ('pending', 'exported'))
    ORDER BY c.range_start ASC
    LIMIT $3
    """

    case SQL.query(Repo, sql, [entry.table, Config.export_lag_hours(), limit],
           timeout: @query_timeout_ms
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [chunk_name, range_start, range_end, status, attempts, row_count] ->
          %{
            chunk_name: chunk_name,
            range_start: range_start,
            range_end: range_end,
            status: status,
            attempts: attempts || 0,
            row_count: row_count
          }
        end)

      {:error, error} ->
        Logger.warning("Cold tier: chunk enumeration failed",
          table: entry.table,
          reason: Exception.message(error)
        )

        []
    end
  end

  defp export_chunk(entry, chunk) do
    if chunk.attempts >= Config.quarantine_attempts() do
      quarantine(entry, chunk)
    else
      attempt_export(entry, chunk)
    end
  end

  # Staging -> verify -> publish (design D2; review F04).
  #
  # Exports NEVER write the published key directly. A COPY is non-preemptible
  # and can leave a complete-but-truncated object (spike 0.3), so writing
  # straight to the key readers glob would make corrupt data instantly
  # query-visible — and a re-export would do it to a key that was previously
  # good. Instead the export lands on a staging key, verification runs against
  # THAT object, and only a verified object is copied onto the published key.
  # Object writes are atomic per key, so readers see the previous good object
  # or the new good one, never a partial or corrupt one.
  defp attempt_export(entry, chunk) do
    published_key = object_key(entry, chunk)
    staging_key = staging_key(entry, chunk)
    record = upsert_manifest(entry, chunk, published_key)

    result =
      Head.session(fn conn ->
        Head.export_range(conn, entry, chunk.range_start, chunk.range_end, staging_key)
        Head.parquet_verification(conn, entry, staging_key)
      end)

    with {:ok, parquet_side} <- result,
         {:ok, primary_side} <- primary_verification(entry, chunk),
         true <- Verification.match?(parquet_side, primary_side),
         :ok <- publish(staging_key, published_key) do
      mark_verified(record, parquet_side, published_key)
      :ok
    else
      false ->
        # The staging object stays for post-mortem; the reconciliation sweep
        # collects it. The published key is untouched and still good.
        record_failure(record, "verification mismatch: parquet != primary")
        :error

      {:error, reason} ->
        record_failure(record, inspect(reason))
        :error
    end
  end

  defp publish(staging_key, published_key) do
    case ObjectStore.copy_object(staging_key, published_key) do
      :ok ->
        # Best-effort: an orphaned staging object is collected by the sweep and
        # never readable (readers only glob the published date= partitions).
        ObjectStore.delete_objects([staging_key])
        :ok

      {:error, reason} ->
        {:error, {:publish_failed, reason}}
    end
  end

  defp primary_verification(entry, chunk) do
    case SQL.query(Repo, Verification.primary_sql(entry), [chunk.range_start, chunk.range_end],
           timeout: @query_timeout_ms
         ) do
      {:ok, %{rows: [row]}} -> {:ok, Verification.to_result(row)}
      {:error, error} -> {:error, error}
    end
  end

  # Every manifest status transition (pending on (re-)export, verified on
  # success, pending on failure, quarantined) takes the per-table cold-tier
  # lock (review F02). This is the OTHER half of the drop gate's serialization:
  # the gate holds the same lock across its checks + drop, so a chunk can never
  # flip verified<->pending between the gate's contiguous-verified read and its
  # drift check. The lock is held only for this fast write, never across the
  # non-preemptible COPY (which runs between the pending and verified flips).
  defp upsert_manifest(entry, chunk, object_key) do
    RetentionFence.with_table_lock(entry.table, fn ->
      ChunkExport
      |> Ash.Changeset.for_create(:create, %{
        table_name: entry.table,
        chunk_name: chunk.chunk_name,
        range_start: chunk.range_start,
        range_end: chunk.range_end,
        object_keys: [object_key],
        status: :pending,
        attempts: chunk.attempts + 1,
        exported_at: DateTime.utc_now()
      })
      |> Ash.create!(actor: SystemActor.system(:cold_tier_exporter))
    end)
  end

  defp mark_verified(record, verification, published_key) do
    RetentionFence.with_table_lock(record.table_name, fn ->
      record
      |> Ash.Changeset.for_update(:update, %{
        status: :verified,
        row_count: verification.row_count,
        bytes: object_bytes([published_key]),
        content_checksum: verification.checksum,
        last_error: nil,
        verified_at: DateTime.utc_now()
      })
      |> Ash.update!(actor: SystemActor.system(:cold_tier_exporter))
    end)
  end

  # Actual on-disk size of the verified objects, so `cold_bytes` telemetry and
  # the control plane's storage projection reflect reality rather than 0.
  # Best-effort: a listing failure must not fail an otherwise-verified export
  # (the size is reporting, not correctness), so it records nil and the next
  # reconciliation pass can fill it.
  defp object_bytes(object_keys) do
    object_keys
    |> Enum.reduce(0, fn key, acc ->
      case ObjectStore.list_objects(key) do
        {:ok, objects} ->
          acc + (objects |> Enum.filter(&(&1.key == key)) |> Enum.map(& &1.size) |> Enum.sum())

        {:error, _} ->
          acc
      end
    end)
    |> case do
      0 -> nil
      bytes -> bytes
    end
  end

  defp record_failure(record, reason) do
    Logger.warning("Cold tier: chunk export failed",
      table: record.table_name,
      chunk: record.chunk_name,
      attempts: record.attempts,
      reason: reason
    )

    RetentionFence.with_table_lock(record.table_name, fn ->
      record
      |> Ash.Changeset.for_update(:update, %{status: :pending, last_error: reason})
      |> Ash.update!(actor: SystemActor.system(:cold_tier_exporter))
    end)
  end

  defp quarantine(entry, chunk) do
    Logger.error(
      "Cold tier: chunk quarantined after repeated export failures — frontier is blocked; " <>
        "operator action required (see break-glass export runbook)",
      table: entry.table,
      chunk: chunk.chunk_name,
      attempts: chunk.attempts
    )

    table = entry.table
    chunk_name = chunk.chunk_name

    RetentionFence.with_table_lock(table, fn ->
      ChunkExport
      |> Ash.Query.filter(table_name == ^table and chunk_name == ^chunk_name)
      |> Ash.read_one(actor: SystemActor.system(:cold_tier_exporter))
      |> case do
        {:ok, %ChunkExport{} = record} ->
          record
          |> Ash.Changeset.for_update(:update, %{status: :quarantined})
          |> Ash.update!(actor: SystemActor.system(:cold_tier_exporter))

        _ ->
          :ok
      end
    end)

    :quarantined
  end

  # --- frontier / boundary ---

  defp advance_frontier(entry) do
    with {:ok, frontier} when not is_nil(frontier) <- compute_frontier(entry),
         :ok <- persist_frontier(entry.table, frontier),
         {:ok, {:ok, effective}} <- Head.session(&Head.ack_boundary(&1, entry.table, frontier)) do
      # The head clamps B monotonically and returns what it actually stored;
      # the primary must record that SAME effective value, never the raw
      # candidate, or the two sides can disagree about the split point.
      persist_acked_boundary(entry.table, effective)
    else
      {:ok, nil} ->
        :ok

      {:error, reason} ->
        # Safe direction: B stays stale-low on the primary; drops stall.
        Logger.warning("Cold tier: boundary ack failed; drop gate will hold",
          table: entry.table,
          reason: inspect(reason)
        )

        :ok
    end
  end

  # F = range_start of the oldest chunk NOT verified (any age), or now() when
  # every chunk is verified. Everything strictly below F is verified-durable.
  defp compute_frontier(entry) do
    sql = """
    SELECT coalesce(
      (
        SELECT min(c.range_start)
        FROM timescaledb_information.chunks c
        LEFT JOIN platform.cold_chunk_exports m
          ON m.table_name = $1 AND m.chunk_name = c.chunk_name AND m.status = 'verified'
        WHERE c.hypertable_schema = 'platform'
          AND c.hypertable_name = $1
          AND m.id IS NULL
      ),
      now()
    )
    """

    case SQL.query(Repo, sql, [entry.table], timeout: @query_timeout_ms) do
      {:ok, %{rows: [[frontier]]}} -> {:ok, frontier}
      {:error, error} -> {:error, error}
    end
  end

  defp persist_frontier(table_name, frontier) do
    # Precise upsert semantics matter here (never regress F, never touch B):
    # raw SQL keeps the invariant arithmetic explicit.
    sql = """
    INSERT INTO platform.cold_tier_boundaries (table_name, frontier, updated_at)
    VALUES ($1, $2, now())
    ON CONFLICT (table_name) DO UPDATE
      SET frontier = GREATEST(platform.cold_tier_boundaries.frontier, EXCLUDED.frontier),
          updated_at = now()
    """

    case SQL.query(Repo, sql, [table_name, frontier], timeout: @query_timeout_ms) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp persist_acked_boundary(table_name, boundary) do
    # B only advances (never regresses), and only after the head ack.
    sql = """
    UPDATE platform.cold_tier_boundaries
    SET query_boundary = GREATEST(coalesce(query_boundary, $2), $2),
        boundary_acked_at = now(),
        updated_at = now()
    WHERE table_name = $1
    """

    case SQL.query(Repo, sql, [table_name, boundary], timeout: @query_timeout_ms) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # Actively re-assert the fence at the START of every run (review F07).
  #
  # The nightly retention worker also reconciles policies, but the exporter
  # runs hourly — removing any in-DB retention policy here shrinks the window
  # during which the TimescaleDB background worker could drop un-exported
  # chunks (e.g. right after cold-tier activation, or after a migration
  # re-armed one) from up to a day down to at most one export interval.
  # Removal is idempotent.
  defp enforce_fence do
    removal_failures =
      Enum.reduce(Registry.tables(), [], fn entry, failures ->
        case RetentionFence.reconcile_policy(entry.table, Registry.hot_retention_days(entry)) do
          :ok -> failures
          {:error, reason} -> [{entry.table, reason} | failures]
        end
      end)

    if removal_failures != [] do
      Logger.error(
        "Cold tier: could not remove in-database retention policies on fenced tables — " <>
          "the TimescaleDB background worker may drop un-exported chunks until this clears",
        failures: inspect(removal_failures)
      )
    end

    case RetentionFence.policy_violations() do
      {:ok, []} ->
        :ok

      {:ok, tables} ->
        Logger.error(
          "Cold tier: in-database retention policies still present on fenced tables after " <>
            "removal — a migration or manual DDL re-armed them; the TimescaleDB background " <>
            "worker may drop un-exported chunks",
          tables: tables
        )

      {:error, reason} ->
        # Can't confirm the fence is intact — treat it as unconfirmed, not clean.
        Logger.error(
          "Cold tier: could not verify retention-policy state on fenced tables — " <>
            "treat the fence as unconfirmed until this clears",
          reason: inspect(reason)
        )
    end

    case RetentionFence.stale_invalidations() do
      [] ->
        :ok

      stale ->
        Logger.warning(
          "Cold tier: pending CAGG invalidations older than the hot boundary — " <>
            "a refresh covering these ranges would delete materialized history; " <>
            "verify refresh windows are clamped (see migration 20260716210000)",
          stale: inspect(stale)
        )
    end
  end

  defp object_key(entry, chunk) do
    date = DateTime.to_date(chunk.range_start)
    "#{Registry.object_prefix(entry, date)}/#{chunk_relname(chunk)}.parquet"
  end

  # Staging lives OUTSIDE the hive-partitioned `date=` prefixes that readers
  # glob, so an in-flight or failed export is never query-visible. The key is
  # deterministic per chunk, so a retry overwrites its own staging object
  # rather than accumulating garbage.
  defp staging_key(entry, chunk) do
    "cold/#{Registry.layout_version()}/#{entry.table}/_staging/#{chunk_relname(chunk)}.parquet"
  end

  defp chunk_relname(chunk), do: chunk.chunk_name |> String.split(".") |> List.last()
end
