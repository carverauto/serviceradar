defmodule ServiceRadar.Repo.Migrations.CreateSweepLeaseDeliveries do
  @moduledoc """
  What core has delivered of each sweep schedule lease, and what the agent acknowledged.

  One row per producer assignment. `lease_id` and `lease_issued_at` name the lease last pushed
  and its signed issuance time (every push of one lease signs the same `not_before`, so a slot
  delivered earlier stays inside the newest production capability). `delivered_window_end` is
  how far the delivered window reaches, so the next push can carry only the newly minted tail.
  The ack columns hold the agent's answer to the latest push it acknowledged; an ack whose
  payload digest differs from `delivered_payload_sha256` answers an older push.
  """
  use Ecto.Migration

  @table "sweep_lease_deliveries"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      producer_assignment_id   UUID         PRIMARY KEY
                               REFERENCES #{schema}.sweep_producer_assignments (id) ON DELETE CASCADE,
      sweep_group_id           UUID         NOT NULL
                               REFERENCES #{schema}.sweep_groups (id) ON DELETE CASCADE,
      agent_id                 TEXT         NOT NULL,
      lease_id                 UUID         NOT NULL,
      lease_issued_at          TIMESTAMPTZ  NOT NULL,
      delivered_window_end     TIMESTAMPTZ  NOT NULL,
      delivered_payload_sha256 TEXT         NOT NULL,
      delivered_at             TIMESTAMPTZ  NOT NULL,
      acked_payload_sha256     TEXT,
      ack_installed            BOOLEAN,
      ack_error                TEXT,
      acked_through            TIMESTAMPTZ,
      acked_slot_count         INTEGER,
      acked_at                 TIMESTAMPTZ,
      inserted_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
      updated_at               TIMESTAMPTZ  NOT NULL DEFAULT now(),
      CONSTRAINT sweep_lease_deliveries_digest_chk
        CHECK (delivered_payload_sha256 ~ '^[0-9a-f]{64}$')
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS sweep_lease_deliveries_group_agent_uidx
      ON #{schema}.#{@table} (sweep_group_id, agent_id)
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
