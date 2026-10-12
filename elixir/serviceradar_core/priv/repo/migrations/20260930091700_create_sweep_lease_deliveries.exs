defmodule ServiceRadar.Repo.Migrations.CreateSweepLeaseDeliveries do
  @moduledoc """
  What core has delivered of each sweep schedule lease, and what the agent acknowledged.

  One row per producer assignment. The row has no foreign keys: it outlives the assignment and
  the group, so destroying either leaves it for the lease pass to revoke on the control stream
  and delete once the session accepted it. `producer_assignment_id` is the primary key and
  `(sweep_group_id, agent_id)` is unique.

  `lease_id` and `lease_issued_at` name the lease last pushed and its signed issuance time
  (every push of one lease signs the same `not_before`, so a slot delivered earlier stays
  inside the newest production capability). `delivered_window_end` is the cursor, just after
  the last slot the push carried, so the next tail starts there. An empty full push carries
  no slot, and its cursor is the window start it sent. `delivered_high_water` is the furthest
  window end sent for the current lease id, how far the agent may still hold slots; a new
  lease id starts it at that push's window end. A same-lease full push tells the agent a
  window that reaches the high water, so a retry still clears every slot the agent may hold,
  and a drop is looked for up to that high water. The ack columns hold the agent's answer to
  the push whose digest is `delivered_payload_sha256`. Any other ack is ignored.
  """
  use Ecto.Migration

  @table "sweep_lease_deliveries"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      producer_assignment_id   UUID         PRIMARY KEY,
      sweep_group_id           UUID         NOT NULL,
      agent_id                 TEXT         NOT NULL,
      lease_id                 UUID         NOT NULL,
      lease_issued_at          TIMESTAMPTZ  NOT NULL,
      delivered_window_end     TIMESTAMPTZ  NOT NULL,
      delivered_high_water     TIMESTAMPTZ  NOT NULL,
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
