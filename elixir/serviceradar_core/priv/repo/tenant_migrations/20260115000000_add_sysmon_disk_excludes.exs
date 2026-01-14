defmodule ServiceRadar.Repo.TenantMigrations.AddSysmonDiskExcludes do
  @moduledoc """
  Adds disk exclusion paths to sysmon profiles and updates defaults.
  """

  use Ecto.Migration

  def up do
    schema = prefix() || "public"

    execute """
    ALTER TABLE IF EXISTS #{schema}.sysmon_profiles
    ADD COLUMN IF NOT EXISTS disk_exclude_paths text[] NOT NULL DEFAULT ARRAY[]::text[]
    """

    execute """
    ALTER TABLE IF EXISTS #{schema}.sysmon_profiles
    ALTER COLUMN disk_paths SET DEFAULT ARRAY[]::text[]
    """

    execute """
    UPDATE #{schema}.sysmon_profiles
    SET disk_paths = ARRAY[]::text[],
        disk_exclude_paths = ARRAY[]::text[]
    WHERE is_default = true
    """
  end

  def down do
    schema = prefix() || "public"

    execute """
    ALTER TABLE IF EXISTS #{schema}.sysmon_profiles
    DROP COLUMN IF EXISTS disk_exclude_paths
    """

    execute """
    ALTER TABLE IF EXISTS #{schema}.sysmon_profiles
    ALTER COLUMN disk_paths SET DEFAULT ARRAY['/']::text[]
    """

    execute """
    UPDATE #{schema}.sysmon_profiles
    SET disk_paths = ARRAY['/']::text[]
    WHERE is_default = true
    """
  end
end
