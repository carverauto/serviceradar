defmodule ServiceRadar.Repo.Migrations.CreateEdgeRecordLedger do
  @moduledoc """
  Minimum-slice persistence for the durable edge-record wire format (task 0.12 /
  5.2, minimum slice only -- NOT the full 64-partition/chronological-DROP design
  in `openspec/changes/unify-sweep-results-proto/design.md`).

  Four tables, each doing exactly one job in the idempotent-CNPG-transaction
  acceptance group:

    * `event_ledger` -- keyed ONLY by `(network_scope_id, event_id)`. The
      semantic-replay/conflict boundary: a redelivered frame whose
      `semantic_envelope_sha256` matches is a replay (idempotent no-op); a
      different digest under the same key is `EVENT_ID_CONFLICT`.
    * `edge_delivery_slots` -- the frozen `edge_slot` coordinate
      `(network_scope_id, authenticated_agent_id, spool_id, sequence)`
      immutably bound to `record_sha256`. This is a TRANSPORT-integrity check,
      independent of the semantic ledger above: the same slot reused with
      different bytes is a distinct conflict outcome.
    * `edge_sweep_batch_slots` -- keyed by the batch coordinate already carried
      on `SweepObservationBatchV1`
      (`network_scope_id, execution_id, execution_shard, assignment_epoch,
      batch_sequence`), binding `event_id`/`semantic_envelope_sha256`/row
      counts the same replay-vs-conflict way.
    * `edge_sweep_projected_rows` -- the minimal atomic domain-projection
      artifact. One row per `(kind, batch_index, element_index)` coordinate
      enumerated by `ServiceRadar.Edge.ProjectionRows.sweep/1`, keyed by
      `ServiceRadar.Edge.ProjectionRows.row_key/2` (the Elixir twin of
      `go/pkg/edge/projection/projection.go`'s `RowKey/2`) so a redelivered
      frame upserts instead of duplicating. This is NOT the full OCSF sweep
      domain schema (reachability/open-port/port-error field projection) --
      that belongs to task 5.1's decoder and a later, larger migration. It is
      the smallest artifact that proves "no duplicate domain rows" under
      forced redelivery.

  None of these tables are hash-subshard/time-bucket partitioned; that
  production sizing is explicitly out of scope for task 0.12's first green
  vertical slice.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:event_ledger, primary_key: false, prefix: @prefix) do
      add(:network_scope_id, :uuid, null: false, primary_key: true)
      add(:event_id, :uuid, null: false, primary_key: true)
      add(:semantic_envelope_sha256, :binary, null: false)
      add(:record_sha256, :binary, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      constraint(:event_ledger, :event_ledger_semantic_digest_length,
        check: "octet_length(semantic_envelope_sha256) = 32",
        prefix: @prefix
      )
    )

    create(
      constraint(:event_ledger, :event_ledger_record_digest_length,
        check: "octet_length(record_sha256) = 32",
        prefix: @prefix
      )
    )

    create table(:edge_delivery_slots, primary_key: false, prefix: @prefix) do
      add(:network_scope_id, :uuid, null: false, primary_key: true)
      add(:authenticated_agent_id, :binary, null: false, primary_key: true)
      add(:spool_id, :uuid, null: false, primary_key: true)
      add(:sequence, :bigint, null: false, primary_key: true)
      add(:record_sha256, :binary, null: false)
      add(:event_id, :uuid, null: false)
      add(:semantic_envelope_sha256, :binary, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      constraint(:edge_delivery_slots, :edge_delivery_slots_record_digest_length,
        check: "octet_length(record_sha256) = 32",
        prefix: @prefix
      )
    )

    create(
      constraint(:edge_delivery_slots, :edge_delivery_slots_semantic_digest_length,
        check: "octet_length(semantic_envelope_sha256) = 32",
        prefix: @prefix
      )
    )

    create(
      constraint(:edge_delivery_slots, :edge_delivery_slots_sequence_positive,
        check: "sequence >= 1",
        prefix: @prefix
      )
    )

    create(
      index(:edge_delivery_slots, [:event_id],
        name: :edge_delivery_slots_event_id_idx,
        prefix: @prefix
      )
    )

    create table(:edge_sweep_batch_slots, primary_key: false, prefix: @prefix) do
      add(:network_scope_id, :uuid, null: false, primary_key: true)
      add(:execution_id, :uuid, null: false, primary_key: true)
      # bigint, not integer: the wire field is uint32 (up to 4294967295), which
      # overflows Postgres's signed 32-bit `integer` -- the exact class of
      # silent-narrowing bug already caught once for mtr_hops.asn (tasks.md
      # task 5.4).
      add(:execution_shard, :bigint, null: false, primary_key: true)
      add(:assignment_epoch, :bigint, null: false, primary_key: true)
      add(:batch_sequence, :bigint, null: false, primary_key: true)
      add(:event_id, :uuid, null: false)
      add(:semantic_envelope_sha256, :binary, null: false)
      add(:projected_row_count, :integer, null: false)
      add(:committed_row_count, :integer, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      constraint(:edge_sweep_batch_slots, :edge_sweep_batch_slots_semantic_digest_length,
        check: "octet_length(semantic_envelope_sha256) = 32",
        prefix: @prefix
      )
    )

    create(
      index(:edge_sweep_batch_slots, [:event_id],
        name: :edge_sweep_batch_slots_event_id_idx,
        prefix: @prefix
      )
    )

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
  end

  def down do
    drop_if_exists(table(:edge_sweep_projected_rows, prefix: @prefix))
    drop_if_exists(table(:edge_sweep_batch_slots, prefix: @prefix))
    drop_if_exists(table(:edge_delivery_slots, prefix: @prefix))
    drop_if_exists(table(:event_ledger, prefix: @prefix))
  end
end
