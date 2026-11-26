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
  lock disabled.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:edge_sweep_projected_rows, [:inserted_at],
        prefix: "platform",
        name: "edge_sweep_projected_rows_inserted_at_idx",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:edge_sweep_projected_rows, [:inserted_at],
        prefix: "platform",
        name: "edge_sweep_projected_rows_inserted_at_idx",
        concurrently: true
      )
    )
  end
end
