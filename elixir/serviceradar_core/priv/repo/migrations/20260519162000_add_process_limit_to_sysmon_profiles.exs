defmodule ServiceRadar.Repo.Migrations.AddProcessLimitToSysmonProfiles do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE platform.sysmon_profiles
    ADD COLUMN IF NOT EXISTS process_limit integer NOT NULL DEFAULT 0
    """)
  end

  def down do
    execute("""
    ALTER TABLE platform.sysmon_profiles
    DROP COLUMN IF EXISTS process_limit
    """)
  end
end
