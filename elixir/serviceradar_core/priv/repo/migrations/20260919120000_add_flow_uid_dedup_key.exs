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

  `platform.ocsf_network_activity` is a large TimescaleDB hypertable and this
  runs during service startup, so the index is built one chunk per transaction
  rather than holding a hypertable-wide lock against EventWriter's flow inserts
  for the whole scan. TimescaleDB requires that option to run outside Ecto's DDL
  transaction and migration lock.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @table "ocsf_network_activity"

  def up do
    execute("ALTER TABLE #{@schema}.#{@table} ADD COLUMN IF NOT EXISTS flow_uid text")

    build_options =
      if hypertable?(),
        do: "WITH (timescaledb.transaction_per_chunk)",
        else: ""

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_ocsf_network_activity_flow_uid
    ON #{@schema}.#{@table} (flow_uid, time)
    WHERE flow_uid IS NOT NULL
    #{build_options}
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@schema}.idx_ocsf_network_activity_flow_uid")
    execute("ALTER TABLE #{@schema}.#{@table} DROP COLUMN IF EXISTS flow_uid")
  end

  defp hypertable? do
    case repo().query!("SELECT to_regclass('timescaledb_information.hypertables')") do
      %{rows: [[nil]]} ->
        false

      %{rows: [[_hypertables_view]]} ->
        %{rows: [[hypertable?]]} =
          repo().query!("""
          SELECT EXISTS (
            SELECT 1
            FROM timescaledb_information.hypertables
            WHERE hypertable_schema = '#{@schema}'
              AND hypertable_name = '#{@table}'
          )
          """)

        hypertable?
    end
  end
end
