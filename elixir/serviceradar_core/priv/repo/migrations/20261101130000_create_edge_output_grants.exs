defmodule ServiceRadar.Repo.Migrations.CreateEdgeOutputGrants do
  @moduledoc """
  One standing output grant per (agent, output contract): the identity, scope and fence a
  passive producer's edge records are signed and checked under (`producer_assignment_id` is the
  grant id, plus `network_scope_id`, `run_shard` and `authority_epoch`).

  `authority_epoch` only moves up. It is bumped in place by an atomic UPDATE and never reused,
  including when a revoked grant is reactivated.
  """
  use Ecto.Migration

  @table "edge_output_grants"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      id                UUID         PRIMARY KEY,
      agent_id          TEXT         NOT NULL,
      contract_id       TEXT         NOT NULL,
      network_scope_id  UUID         NOT NULL,
      run_shard         BIGINT       NOT NULL DEFAULT 0,
      authority_epoch   BIGINT       NOT NULL DEFAULT 1,
      state             TEXT         NOT NULL DEFAULT 'active',
      epoch_reason      TEXT         NOT NULL DEFAULT 'created',
      epoch_changed_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
      revoked_at        TIMESTAMPTZ,
      inserted_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
      updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
      CONSTRAINT edge_output_grants_epoch_chk CHECK (authority_epoch >= 1),
      CONSTRAINT edge_output_grants_shard_chk CHECK (run_shard >= 0 AND run_shard <= 4294967295),
      CONSTRAINT edge_output_grants_state_chk CHECK (state IN ('active', 'revoked')),
      CONSTRAINT edge_output_grants_revoked_chk
        CHECK ((state = 'revoked') = (revoked_at IS NOT NULL))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS edge_output_grants_agent_contract_uidx
      ON #{schema}.#{@table} (agent_id, contract_id)
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
