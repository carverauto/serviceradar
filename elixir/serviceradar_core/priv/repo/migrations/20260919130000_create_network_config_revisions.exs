defmodule ServiceRadar.Repo.Migrations.CreateNetworkConfigRevisions do
  @moduledoc """
  Retrieved device running/startup configs. Bodies stay in CNPG; they are
  never written as Dgraph predicates.
  """
  use Ecto.Migration

  @table "network_config_revisions"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
      device_uid      TEXT         NOT NULL,
      source          TEXT         NOT NULL,
      config_kind     TEXT         NOT NULL,
      retrieved_at    TIMESTAMPTZ  NOT NULL,
      content_hash    TEXT         NOT NULL,
      body            TEXT         NOT NULL,
      parser_version  TEXT         NOT NULL DEFAULT 'network_config_v1',
      inserted_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
      updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
      CONSTRAINT network_config_revisions_kind_chk
        CHECK (config_kind IN ('running', 'startup'))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS network_config_revisions_device_hash_uidx
      ON #{schema}.#{@table} (device_uid, content_hash)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS network_config_revisions_device_retrieved_idx
      ON #{schema}.#{@table} (device_uid, retrieved_at DESC)
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
