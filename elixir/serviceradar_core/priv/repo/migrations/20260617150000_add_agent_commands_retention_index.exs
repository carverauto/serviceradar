defmodule ServiceRadar.Repo.Migrations.AddAgentCommandsRetentionIndex do
  @moduledoc """
  Adds a partial index that backs the agent-command retention sweep.

  Live demo evidence (cnpg-23 primary, 2026-06-17): platform.agent_commands held
  97k rows / 125 MB, of which 99.7% were older than a day, and the only index was
  the `command_id` primary key. The retention sweep's `WHERE inserted_at < $1`
  predicate was the #2 hot path on the demo DB (~18s mean, ~15% of total exec
  time), seq-scanning the whole table on every run.

  The companion code change drops the implicit `::timestamp` cast (the retention
  worker now compares the timestamptz `inserted_at` column against a
  `:utc_datetime_usec` bound) and only ever deletes terminal-state rows. This
  index mirrors that predicate exactly: a partial B-tree on `inserted_at`
  restricted to terminal statuses. Because ~all deletable rows are terminal it
  stays small, and Postgres can satisfy the sweep with an index range scan
  instead of a full seq scan.

  NOTE: the index is inert until the companion cast fix in
  `ServiceRadar.Edge.AgentCommandCleanupWorker` lands -- the old
  `inserted_at::timestamp < $1` predicate casts the indexed column and cannot use
  this (or any) `inserted_at` index. Ship them together.

  Built `CONCURRENTLY` (with `@disable_ddl_transaction` /
  `@disable_migration_lock`) so it does not take an `ACCESS EXCLUSIVE` lock on the
  live, write-hot table while the index is built.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @table "agent_commands"

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_agent_commands_terminal_inserted_at
    ON #{@schema}.#{@table} (inserted_at)
    WHERE status IN ('completed', 'failed', 'expired', 'canceled', 'offline')
    """)
  end

  def down do
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.idx_agent_commands_terminal_inserted_at"
    )
  end
end
