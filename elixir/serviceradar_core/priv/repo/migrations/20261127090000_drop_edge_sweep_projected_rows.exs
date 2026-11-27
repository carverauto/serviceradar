defmodule ServiceRadar.Repo.Migrations.DropEdgeSweepProjectedRows do
  @moduledoc """
  Drops `platform.edge_sweep_projected_rows` (#7069).

  The sweep projector stopped writing the table and the edge-ledger retention worker
  stopped pruning it in the previous release; nothing reads it. Exactly-once for a
  sweep batch is `event_ledger` plus `edge_sweep_batch_slots`, and the domain writes
  are themselves upserts. Its random `(network_scope_id, row_key)` primary key made
  every insert dirty a random index leaf, which was the largest single statement in
  database time.

  This must not ship in the same release that stops the writer: migrations run before
  new pods start, so a core still running the old projector would fail its sweep batch
  transactions on the missing table during a rolling upgrade.

  `down` recreates the empty table, its check constraint and indexes as
  `20260910120000_create_edge_record_ledger` and
  `20261126070000_index_edge_sweep_projected_rows_inserted_at` defined them.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("DROP TABLE IF EXISTS platform.edge_sweep_projected_rows")
  end

  def down do
    create_if_not_exists table(:edge_sweep_projected_rows, primary_key: false, prefix: @prefix) do
      add(:network_scope_id, :uuid, null: false, primary_key: true)
      add(:row_key, :binary, null: false, primary_key: true)
      add(:event_id, :uuid, null: false)
      add(:kind, :text, null: false)
      add(:batch_index, :integer, null: false)
      add(:element_index, :integer, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      constraint(:edge_sweep_projected_rows, :edge_sweep_projected_rows_row_key_length,
        check: "octet_length(row_key) = 32",
        prefix: @prefix
      )
    )

    create_if_not_exists(
      index(:edge_sweep_projected_rows, [:event_id],
        name: :edge_sweep_projected_rows_event_id_idx,
        prefix: @prefix
      )
    )

    create_if_not_exists(
      index(:edge_sweep_projected_rows, [:inserted_at],
        name: :edge_sweep_projected_rows_inserted_at_idx,
        prefix: @prefix
      )
    )
  end
end
