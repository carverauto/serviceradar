defmodule ServiceRadar.Repo.Migrations.CreateSweepExecutionSlots do
  @moduledoc """
  One row per pre-minted sweep execution of a schedule lease: the execution's id (a UUIDv7
  whose time is the slot start), its collection window, the fence it was planned under, and
  the plan a source authorization binds.

  Kept apart from `sweep_group_executions`, which holds runs that happened. A week of
  future slots would otherwise fill the execution lists, the SRQL entity, retention and the
  missed-sweep monitor with rows that have not run. The execution row is created by the
  results ingest under the slot's id when the results arrive.
  """
  use Ecto.Migration

  @table "sweep_execution_slots"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      id                     UUID         PRIMARY KEY,
      sweep_group_id         UUID         NOT NULL
                             REFERENCES #{schema}.sweep_groups (id) ON DELETE CASCADE,
      agent_id               TEXT         NOT NULL,
      producer_assignment_id UUID         NOT NULL
                             REFERENCES #{schema}.sweep_producer_assignments (id) ON DELETE CASCADE,
      network_scope_id       UUID         NOT NULL,
      authority_epoch        BIGINT       NOT NULL,
      lease_id               UUID         NOT NULL,
      slot_start             TIMESTAMPTZ  NOT NULL,
      collection_expires     TIMESTAMPTZ  NOT NULL,
      state                  TEXT         NOT NULL DEFAULT 'scheduled',
      plan_id                UUID         NOT NULL,
      plan_sha256            BYTEA        NOT NULL,
      check_set_sha256       BYTEA        NOT NULL,
      plan_header            BYTEA        NOT NULL,
      plan_pages             BYTEA[]      NOT NULL,
      inserted_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
      updated_at             TIMESTAMPTZ  NOT NULL DEFAULT now(),
      CONSTRAINT sweep_execution_slots_epoch_chk CHECK (authority_epoch >= 1),
      CONSTRAINT sweep_execution_slots_window_chk CHECK (collection_expires > slot_start),
      CONSTRAINT sweep_execution_slots_state_chk CHECK (state IN ('scheduled', 'dropped')),
      CONSTRAINT sweep_execution_slots_plan_chk
        CHECK (octet_length(plan_sha256) = 32 AND octet_length(check_set_sha256) = 32)
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS sweep_execution_slots_assignment_start_uidx
      ON #{schema}.#{@table} (producer_assignment_id, slot_start)
      WHERE state = 'scheduled'
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS sweep_execution_slots_group_unrun_idx
      ON #{schema}.#{@table} (sweep_group_id, slot_start)
      WHERE state = 'scheduled'
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
