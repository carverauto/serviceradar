defmodule ServiceRadar.Repo.Migrations.EdgeIssuerKeyAndPipelineSettings do
  @moduledoc """
  Moves the edge issuer key into CNPG and turns the sweep lease settings into the edge
  pipeline settings (enable-edge-record-pipeline-by-default, design Decisions 1, 6 and 9).

    * `edge_issuer_key` is a singleton row (`id = 'default'`): the Ed25519 public key in
      plaintext and the 32-byte seed encrypted by AshCloak. Core generates it on first use and
      never changes it, so it travels with a database backup.
    * `sweep_lease_settings` becomes `edge_pipeline_settings`. The pipeline has no switch, so
      `leasing_enabled` is dropped. The horizon fields stay, and `spool_max_bytes` is the agent
      spool byte budget; NULL inherits, and the code default is 1 GiB. Its floor of 16 MiB keeps
      room above the agent spool's recovery reserve and free-space headroom.

  `down/0` restores the old table shape. A dropped `leasing_enabled` comes back NULL, which is
  off, and the issuer key row is deleted with its table.
  """
  use Ecto.Migration

  @old "sweep_lease_settings"
  @new "edge_pipeline_settings"
  @renamed_constraints ~w(scope_chk global_key_chk horizon_chk max_chk pkey)

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE #{schema}.edge_issuer_key (
      id             TEXT       PRIMARY KEY DEFAULT 'default',
      public_key     TEXT       NOT NULL,
      encrypted_seed BYTEA      NOT NULL,
      inserted_at    TIMESTAMP  NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      CONSTRAINT edge_issuer_key_singleton CHECK (id = 'default')
    )
    """)

    execute("ALTER TABLE #{schema}.#{@old} RENAME TO #{@new}")

    for suffix <- @renamed_constraints do
      execute(
        "ALTER TABLE #{schema}.#{@new} RENAME CONSTRAINT #{@old}_#{suffix} TO #{@new}_#{suffix}"
      )
    end

    execute("ALTER INDEX #{schema}.#{@old}_scope_uidx RENAME TO #{@new}_scope_uidx")
    execute("ALTER TABLE #{schema}.#{@new} DROP COLUMN leasing_enabled")

    execute("""
    ALTER TABLE #{schema}.#{@new}
      ADD COLUMN spool_max_bytes BIGINT,
      ADD CONSTRAINT #{@new}_spool_max_bytes_chk
        CHECK (spool_max_bytes IS NULL OR spool_max_bytes >= 16777216)
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.#{@new}
      DROP CONSTRAINT #{@new}_spool_max_bytes_chk,
      DROP COLUMN spool_max_bytes,
      ADD COLUMN leasing_enabled BOOLEAN
    """)

    execute("ALTER INDEX #{schema}.#{@new}_scope_uidx RENAME TO #{@old}_scope_uidx")

    for suffix <- @renamed_constraints do
      execute(
        "ALTER TABLE #{schema}.#{@new} RENAME CONSTRAINT #{@new}_#{suffix} TO #{@old}_#{suffix}"
      )
    end

    execute("ALTER TABLE #{schema}.#{@new} RENAME TO #{@old}")
    execute("DROP TABLE #{schema}.edge_issuer_key")
  end
end
