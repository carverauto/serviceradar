defmodule ServiceRadar.Repo.Migrations.BoundSysmonProcessProfileDefaults do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute "ALTER TABLE platform.sysmon_profiles ALTER COLUMN process_limit SET DEFAULT 25"

    execute """
    UPDATE platform.sysmon_profiles
    SET process_limit = 25,
        updated_at = NOW()
    WHERE collect_processes = true
      AND process_limit = 0
    """
  end

  def down do
    execute "ALTER TABLE platform.sysmon_profiles ALTER COLUMN process_limit SET DEFAULT 0"
  end
end
