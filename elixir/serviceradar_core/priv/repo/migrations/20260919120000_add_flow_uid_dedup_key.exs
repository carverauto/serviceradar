defmodule ServiceRadar.Repo.Migrations.AddFlowUidDedupKey do
  @moduledoc """
  Carries the EventWriter record identity onto `platform.ocsf_network_activity`
  and makes it the table's deduplication key.

  The hypertable has no primary key and no unique constraint, so the flow
  processor's `on_conflict: :nothing` had nothing to conflict on and a
  redelivered JetStream batch inserted a second copy of every row. `flow_uid`
  is `ServiceRadar.Analytics.StarRocks.Identity.record_id/2`, the same identity
  the warehouse row is keyed on, so both stores collapse a redelivery the same
  way.

  The unique index is partial on `flow_uid IS NOT NULL`: rows written before
  this migration carry no identity, so it starts empty and cannot fail to build
  on history that already holds duplicates. TimescaleDB requires the
  partitioning column in a unique index, hence `(flow_uid, time)`.

  The index is built with a plain `CREATE UNIQUE INDEX`, which holds a
  hypertable-wide lock for the scan. That is not an oversight: TimescaleDB
  offers no bounded build for a UNIQUE index on a hypertable. Both candidates
  are refused outright -- `WITH (timescaledb.transaction_per_chunk)` answers
  `cannot use timescaledb.transaction_per_chunk with UNIQUE or PRIMARY KEY`
  (the option works on a non-unique index, so the refusal is about UNIQUE), and
  `CONCURRENTLY` answers `hypertables do not support concurrent index creation`.
  Do not reintroduce either; the scan is bounded in practice because the partial
  predicate matches no pre-existing row.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @table "ocsf_network_activity"

  def up do
    execute("ALTER TABLE #{@schema}.#{@table} ADD COLUMN IF NOT EXISTS flow_uid text")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_ocsf_network_activity_flow_uid
    ON #{@schema}.#{@table} (flow_uid, time)
    WHERE flow_uid IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@schema}.idx_ocsf_network_activity_flow_uid")
    execute("ALTER TABLE #{@schema}.#{@table} DROP COLUMN IF EXISTS flow_uid")
  end
end
