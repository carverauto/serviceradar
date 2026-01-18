defmodule ServiceRadar.Repo.Migrations.AddOtelLogFields do
  @moduledoc """
  Adds missing OpenTelemetry log fields to the logs table.
  """

  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE IF EXISTS logs
      ADD COLUMN IF NOT EXISTS observed_timestamp TIMESTAMPTZ,
      ADD COLUMN IF NOT EXISTS trace_flags INT,
      ADD COLUMN IF NOT EXISTS event_name TEXT,
      ADD COLUMN IF NOT EXISTS scope_attributes TEXT
    """)
  end

  def down do
    execute("""
    ALTER TABLE IF EXISTS logs
      DROP COLUMN IF EXISTS scope_attributes,
      DROP COLUMN IF EXISTS event_name,
      DROP COLUMN IF EXISTS trace_flags,
      DROP COLUMN IF EXISTS observed_timestamp
    """)
  end
end
