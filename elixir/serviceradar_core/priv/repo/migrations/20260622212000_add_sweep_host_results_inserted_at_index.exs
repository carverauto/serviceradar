defmodule ServiceRadar.Repo.Migrations.AddSweepHostResultsInsertedAtIndex do
  @moduledoc """
  Adds an `inserted_at` index for the sweep-host-results retention scan.

  The retention worker repeatedly runs `SELECT id FROM platform.sweep_host_results
  WHERE inserted_at < $1 ORDER BY inserted_at LIMIT N`. With no index on
  `inserted_at`, the planner does a Parallel Seq Scan + Sort of the whole
  2.8M-row / ~480MB table (live EXPLAIN cost up to ~475k) every batch — the
  largest avoidable `seq_tup_read` source on the primary.

  A btree on `inserted_at` turns it into a range scan + LIMIT. Built
  `CONCURRENTLY` + `IF NOT EXISTS`; purely additive, results unchanged.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS sweep_host_results_inserted_at_idx
    ON platform.sweep_host_results (inserted_at)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.sweep_host_results_inserted_at_idx")
  end
end
