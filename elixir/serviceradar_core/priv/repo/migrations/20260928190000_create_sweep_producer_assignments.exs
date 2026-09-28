defmodule ServiceRadar.Repo.Migrations.CreateSweepProducerAssignments do
  @moduledoc """
  One producer assignment per (sweep group, agent): the identity, scope and fence
  the durable edge-record path signs and checks (`producer_assignment_id`,
  `network_scope_id`, `run_shard`, `authority_epoch`).

  `authority_epoch` only moves up. It is bumped in place by an atomic UPDATE and
  never reused, including when a revoked assignment is reactivated.
  """
  use Ecto.Migration

  @table "sweep_producer_assignments"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
      sweep_group_id    UUID         NOT NULL
                        REFERENCES #{schema}.sweep_groups (id) ON DELETE CASCADE,
      agent_id          TEXT         NOT NULL,
      network_scope_id  UUID         NOT NULL,
      run_shard         BIGINT       NOT NULL DEFAULT 0,
      authority_epoch   BIGINT       NOT NULL DEFAULT 1,
      state             TEXT         NOT NULL DEFAULT 'active',
      epoch_reason      TEXT         NOT NULL DEFAULT 'created',
      epoch_changed_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
      revoked_at        TIMESTAMPTZ,
      inserted_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
      updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
      CONSTRAINT sweep_producer_assignments_epoch_chk
        CHECK (authority_epoch >= 1),
      CONSTRAINT sweep_producer_assignments_shard_chk
        CHECK (run_shard >= 0 AND run_shard <= 4294967295),
      CONSTRAINT sweep_producer_assignments_state_chk
        CHECK (state IN ('active', 'revoked')),
      CONSTRAINT sweep_producer_assignments_revoked_chk
        CHECK ((state = 'revoked') = (revoked_at IS NOT NULL))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS sweep_producer_assignments_group_agent_uidx
      ON #{schema}.#{@table} (sweep_group_id, agent_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS sweep_producer_assignments_agent_active_idx
      ON #{schema}.#{@table} (agent_id)
      WHERE state = 'active'
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
