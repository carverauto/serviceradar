defmodule ServiceRadar.Repo.Migrations.AddLogsSourceIp do
  @moduledoc """
  Adds the optional collector-observed source IP to platform logs.
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE IF EXISTS #{prefix() || "platform"}.logs
      ADD COLUMN IF NOT EXISTS source_ip TEXT
    """)
  end

  def down do
    execute("""
    ALTER TABLE IF EXISTS #{prefix() || "platform"}.logs
      DROP COLUMN IF EXISTS source_ip
    """)
  end
end
