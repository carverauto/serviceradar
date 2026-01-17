defmodule ServiceRadar.Repo.Migrations.DropPublicSysmonProfiles do
  @moduledoc """
  Drops the legacy public sysmon_profiles table.

  Sysmon profiles are instance-scoped and should live in the instance schema.
  """

  use Ecto.Migration

  def up do
    execute "DROP TABLE IF EXISTS sysmon_profiles CASCADE"
  end

  def down do
    execute """
    CREATE TABLE IF NOT EXISTS sysmon_profiles (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      name text NOT NULL,
      description text,
      sample_interval text NOT NULL DEFAULT '10s',
      collect_cpu boolean NOT NULL DEFAULT true,
      collect_memory boolean NOT NULL DEFAULT true,
      collect_disk boolean NOT NULL DEFAULT true,
      collect_network boolean NOT NULL DEFAULT false,
      collect_processes boolean NOT NULL DEFAULT false,
      disk_paths text[] NOT NULL DEFAULT ARRAY['/']::text[],
      thresholds jsonb NOT NULL DEFAULT '{}'::jsonb,
      is_default boolean NOT NULL DEFAULT false,
      enabled boolean NOT NULL DEFAULT true,
      target_query text,
      priority integer NOT NULL DEFAULT 0,
      inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      updated_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    )
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS sysmon_profiles_unique_name_index
    ON sysmon_profiles (name)
    """

    execute """
    CREATE INDEX IF NOT EXISTS sysmon_profiles_targeting_index
    ON sysmon_profiles (enabled, is_default, priority)
    WHERE enabled = true AND is_default = false AND target_query IS NOT NULL
    """
  end
end
