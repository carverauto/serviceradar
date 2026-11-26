defmodule ServiceRadar.Repo.Migrations.IndexEdgeSweepProjectedRowsInsertedAt do
  @moduledoc """
  Serves `EdgeLedgerRetentionWorker`'s prune of `edge_sweep_projected_rows`, which selects
  `inserted_at < cutoff ORDER BY inserted_at LIMIT n`.

  With no index on `inserted_at`, every batch that found fewer than `n` expired rows,
  including the final batch of every hourly run, read the whole heap. `inserted_at` only
  grows, so this B-tree takes its inserts at the right edge and adds well under 1% to the
  table's insert I/O, which the random `row_key` primary key dominates. BRIN does not fit:
  its ranges only widen once deleted space is reused.

  The table is written continuously, so the index is built `CONCURRENTLY`, which cannot run
  inside a transaction; hence a migration of its own with the DDL transaction and migration
  lock disabled. A concurrent build that is interrupted leaves an invalid index under this
  name, which `IF NOT EXISTS` would then skip forever while every insert still maintained it,
  so the next run drops an invalid index and rebuilds it.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "edge_sweep_projected_rows_inserted_at_idx"

  @create """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS edge_sweep_projected_rows_inserted_at_idx
  ON platform.edge_sweep_projected_rows (inserted_at)
  """

  def up do
    case index_state(@index) do
      :valid ->
        :ok

      :invalid ->
        execute("DROP INDEX CONCURRENTLY IF EXISTS platform.#{@index}")
        execute(@create)

      :missing ->
        execute(@create)
    end
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.#{@index}")
  end

  defp index_state(name) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT COALESCE(i.indisvalid AND i.indisready AND i.indislive, false)
        FROM pg_class AS c
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        JOIN pg_index AS i ON i.indexrelid = c.oid
        WHERE n.nspname = 'platform' AND c.relname = $1
        """,
        [name]
      )

    case rows do
      [] -> :missing
      [[true]] -> :valid
      [[false]] -> :invalid
    end
  end
end
