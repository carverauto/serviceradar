defmodule ServiceRadar.Repo.Migrations.CreateNetworkChanges do
  @moduledoc """
  Proposed and recorded network changes. Comments stay in CNPG; Dgraph
  holds id, kind, window, status, source, and affects only.
  """
  use Ecto.Migration

  @table "network_changes"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
      external_id   TEXT         NOT NULL,
      source        TEXT         NOT NULL,
      kind          TEXT         NOT NULL,
      window_start  TIMESTAMPTZ  NOT NULL,
      window_end    TIMESTAMPTZ,
      status        TEXT         NOT NULL,
      selector      JSONB        NOT NULL DEFAULT '{}'::jsonb,
      comments      TEXT,
      inserted_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
      updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
      CONSTRAINT network_changes_kind_chk
        CHECK (kind IN ('upgrade', 'config', 'other'))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS network_changes_source_external_uidx
      ON #{schema}.#{@table} (source, external_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS network_changes_window_idx
      ON #{schema}.#{@table} (window_start, window_end)
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
