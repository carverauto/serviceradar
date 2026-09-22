defmodule ServiceRadar.Repo.Migrations.CreateNetworkConfigInterfaceFacts do
  @moduledoc """
  Parsed interface facts for a config revision. Unique on (revision_id, if_name).
  """
  use Ecto.Migration

  @table "network_config_interface_facts"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
      revision_id     UUID         NOT NULL
        REFERENCES #{schema}.network_config_revisions(id) ON DELETE CASCADE,
      device_uid      TEXT         NOT NULL,
      if_name         TEXT         NOT NULL,
      ipv4_prefix     TEXT,
      ipv6_prefix     TEXT,
      vlan            INTEGER,
      description     TEXT,
      shutdown        BOOLEAN      NOT NULL DEFAULT false,
      vrf             TEXT,
      inserted_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
      updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS network_config_interface_facts_revision_if_uidx
      ON #{schema}.#{@table} (revision_id, if_name)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS network_config_interface_facts_device_idx
      ON #{schema}.#{@table} (device_uid)
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
