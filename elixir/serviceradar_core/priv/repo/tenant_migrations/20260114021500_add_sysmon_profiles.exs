defmodule ServiceRadar.Repo.TenantMigrations.AddSysmonProfiles do
  @moduledoc """
  Creates sysmon_profiles table in tenant schemas.

  This mirrors the sysmon profile schema used by the Ash resource and is
  idempotent for environments that may already have the table.
  """

  use Ecto.Migration

  def up do
    schema = prefix()

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.sysmon_profiles (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      tenant_id uuid NOT NULL,
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
    CREATE UNIQUE INDEX IF NOT EXISTS sysmon_profiles_unique_name_per_tenant_index
    ON #{schema}.sysmon_profiles (tenant_id, name)
    """

    execute """
    CREATE INDEX IF NOT EXISTS sysmon_profiles_targeting_index
    ON #{schema}.sysmon_profiles (enabled, is_default, priority)
    WHERE enabled = true AND is_default = false AND target_query IS NOT NULL
    """
  end

  def down do
    schema = prefix()

    execute "DROP TABLE IF EXISTS #{schema}.sysmon_profiles CASCADE"
  end
end
