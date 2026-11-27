defmodule ServiceRadar.Repo.Migrations.DropEdgeSweepProjectedRows do
  @moduledoc """
  Replaces `platform.edge_sweep_projected_rows` with an empty, index-free stub (#7069).

  The sweep projector stopped writing the table and the edge-ledger retention worker
  stopped pruning it in #7096; nothing reads it. Exactly-once for a sweep batch is
  `event_ledger` plus `edge_sweep_batch_slots`, and the domain writes are themselves
  upserts. Its random `(network_scope_id, row_key)` primary key made every insert dirty
  a random index leaf, the largest single statement in database time.

  Why a stub and not a plain drop: migrations run before new pods start. An
  installation upgraded from a release older than #7096 straight to this one would still
  have cores running the old projector during the rollout, and its insert would fail
  every sweep batch transaction on a missing table. The old projector inserts with
  `ON CONFLICT DO NOTHING` and no conflict target, which a table without unique indexes
  accepts. So the real table (and its ~13 GB on the demo deployment) is dropped, and an
  `UNLOGGED` table with the same columns, no primary key, no indexes and no constraints
  takes its name: an old core's rows land in a small heap without WAL or index writes,
  and nothing fails. Rows only arrive while old and new cores coexist. A later release
  that enforces a minimum upgrade version can drop the stub.

  `down` restores the original table, its check constraint and indexes as
  `20260910120000_create_edge_record_ledger` and
  `20261126070000_index_edge_sweep_projected_rows_inserted_at` defined them.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("DROP TABLE IF EXISTS platform.edge_sweep_projected_rows")

    execute("""
    CREATE UNLOGGED TABLE platform.edge_sweep_projected_rows (
      network_scope_id uuid NOT NULL,
      row_key bytea NOT NULL,
      event_id uuid NOT NULL,
      kind text NOT NULL,
      batch_index integer NOT NULL,
      element_index integer NOT NULL,
      inserted_at timestamp without time zone NOT NULL DEFAULT now()
    )
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS platform.edge_sweep_projected_rows")

    create table(:edge_sweep_projected_rows, primary_key: false, prefix: @prefix) do
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

    create(
      index(:edge_sweep_projected_rows, [:event_id],
        name: :edge_sweep_projected_rows_event_id_idx,
        prefix: @prefix
      )
    )

    create(
      index(:edge_sweep_projected_rows, [:inserted_at],
        name: :edge_sweep_projected_rows_inserted_at_idx,
        prefix: @prefix
      )
    )
  end
end
