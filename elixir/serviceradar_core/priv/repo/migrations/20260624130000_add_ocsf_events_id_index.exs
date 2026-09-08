defmodule ServiceRadar.Repo.Migrations.AddOcsfEventsIdIndex do
  @moduledoc """
  Index ocsf_events with `id` as the leading column so the causal_signals
  existing_ocsf_event_times lookup
  (`SELECT id, min(time) FROM ocsf_events WHERE id = ANY($1::uuid[]) GROUP BY id`)
  becomes an index-only seek instead of a full index scan.

  The only id-bearing index was the `(time, id)` primary key. An id-only
  predicate cannot seek it (time leads), so every call scanned the entire pkey
  (~900 MB of buffers per call observed on demo). It became the top DB CPU
  consumer (~36%) once the causal_signals path was unblocked, dropping to ~49
  buffers/call with a `(id, time)` index.

  Note: TimescaleDB hypertables reject `CREATE INDEX CONCURRENTLY`, so this is a
  plain build (brief per-chunk write lock).
  """
  use Ecto.Migration

  # Release the per-chunk ACCESS EXCLUSIVE build lock as soon as each index
  # build finishes, rather than holding it until migration-transaction commit,
  # on a hot multi-million-row ingestion table. Matches the hypertable-index
  # convention in #4279. (CONCURRENTLY remains unavailable on a hypertable.)
  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @table "ocsf_events"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_id_time
    ON #{schema()}.#{@table} (id, time)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{schema()}.idx_ocsf_events_id_time")
  end

  defp schema do
    prefix() || @schema
  end
end
