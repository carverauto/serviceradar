defmodule ServiceRadar.Repo.Migrations.BrinIndexEdgeSweepProjectedRowsInsertedAt do
  @moduledoc """
  Serves `EdgeLedgerRetentionWorker`'s bounded prune of
  `edge_sweep_projected_rows`, whose candidates are `inserted_at < $cutoff`.

  No index covered `inserted_at`, so each prune batch scanned the table from its
  start until it found enough expired rows. Rows are appended in `inserted_at`
  order and expire from the old end, so the column tracks physical order closely
  and a BRIN index lets a batch read only the block ranges that can hold expired
  rows. A BRIN index stays a few hundred kilobytes where a B-tree over every
  projected row would be gigabytes and slow every sweep insert.

  Sweep projection inserts continuously, so the index is built `CONCURRENTLY`,
  in a migration of its own with the DDL transaction and migration lock disabled.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:edge_sweep_projected_rows, [:inserted_at],
        prefix: "platform",
        name: "edge_sweep_projected_rows_inserted_at_brin_idx",
        using: "BRIN",
        options: "autosummarize = on",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:edge_sweep_projected_rows, [:inserted_at],
        prefix: "platform",
        name: "edge_sweep_projected_rows_inserted_at_brin_idx",
        concurrently: true
      )
    )
  end
end
