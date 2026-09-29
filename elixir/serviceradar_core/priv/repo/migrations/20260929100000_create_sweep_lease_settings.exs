defmodule ServiceRadar.Repo.Migrations.CreateSweepLeaseSettings do
  @moduledoc """
  Operator settings for sweep schedule leases: whether core schedules an agent's sweeps
  ahead of time, and how far ahead.

  One row per scope. An agent's row overrides its partition's, which overrides the global
  row; a field left NULL inherits. `max_horizon_seconds` exists only on the global row and
  caps every resolved horizon. With no rows nothing is leased.
  """
  use Ecto.Migration

  @table "sweep_lease_settings"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      id                  UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
      scope               TEXT         NOT NULL,
      scope_key           TEXT         NOT NULL DEFAULT '',
      leasing_enabled     BOOLEAN,
      horizon_seconds     INTEGER,
      max_horizon_seconds INTEGER,
      inserted_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
      updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
      CONSTRAINT sweep_lease_settings_scope_chk
        CHECK (scope IN ('global', 'partition', 'agent')),
      CONSTRAINT sweep_lease_settings_global_key_chk
        CHECK ((scope = 'global') = (scope_key = '')),
      CONSTRAINT sweep_lease_settings_horizon_chk
        CHECK (horizon_seconds IS NULL OR horizon_seconds > 0),
      CONSTRAINT sweep_lease_settings_max_chk
        CHECK (max_horizon_seconds IS NULL OR (scope = 'global' AND max_horizon_seconds > 0))
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS sweep_lease_settings_scope_uidx
      ON #{schema}.#{@table} (scope, scope_key)
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
