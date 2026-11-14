defmodule ServiceRadar.Repo.Migrations.RemoveColdTelemetryTier do
  @moduledoc """
  Removes the cold telemetry tier's database objects (OpenSpec
  remove-cold-telemetry-tier).

  Drops the export manifest and boundary tables that
  `20260716200000_create_cold_tier_manifest` created, revokes the grants that
  `20260716220000_create_cold_tier_export_role` gave the `cold_reader` role,
  drops that role where this connection may manage roles, and deletes waiting
  jobs of the retired exporter and pruner workers.

  Metadata only: no Parquet object a deployment wrote to a bucket is read,
  moved or deleted.

  Role DDL is a cluster-admin privilege that the migration user lacks on a
  default CNPG cluster, where the export-role migration therefore never
  created the role. Revoking needs only ownership of the granted objects, so
  the revokes run wherever the role exists. `DROP ROLE` runs only when this
  connection has `SUPERUSER` or `CREATEROLE`. Like the migration that created
  the role, this one must never be the migration that fails: each role step
  turns an error into a notice, because a role left behind without grants
  can read nothing.
  """

  use Ecto.Migration

  @role "cold_reader"

  # The tables 20260716220000 granted SELECT on. The two manifest tables are
  # dropped first, which removes their grants with them.
  @granted_tables ~w(
    logs
    otel_traces
    otel_metrics
    otel_metric_points
    timeseries_metrics
    ocsf_events
    ocsf_network_activity
  )

  @retired_workers ~w(
    ServiceRadar.ColdTier.Exporter
    ServiceRadar.ColdTier.Pruner
  )

  def up do
    execute("DROP TABLE IF EXISTS platform.cold_chunk_exports")
    execute("DROP TABLE IF EXISTS platform.cold_tier_boundaries")

    execute("""
    DO $$
    DECLARE
      granted text;
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
        RETURN;
      END IF;

      FOREACH granted IN ARRAY ARRAY[#{Enum.map_join(@granted_tables, ", ", &"'#{&1}'")}] LOOP
        IF to_regclass(format('platform.%I', granted)) IS NOT NULL THEN
          EXECUTE format('REVOKE ALL ON platform.%I FROM #{@role}', granted);
        END IF;
      END LOOP;

      REVOKE ALL ON SCHEMA platform FROM #{@role};
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not revoke the grants of role %: %', '#{@role}', SQLERRM;
    END $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
        RETURN;
      END IF;

      IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = current_user AND (rolsuper OR rolcreaterole)
      ) THEN
        DROP ROLE #{@role};
      ELSE
        RAISE NOTICE 'Leaving role % in place: % lacks CREATEROLE.', '#{@role}', current_user;
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not drop role %: %', '#{@role}', SQLERRM;
    END $$;
    """)

    # serviceradar:allow-startup-maintenance
    # Bounded and schema-critical: deletes at most one pending job per retired
    # worker (ServiceRadar.ColdTier.Exporter and ServiceRadar.ColdTier.Pruner,
    # states available/scheduled/retryable only). A fresh install has none.
    # Without it those jobs would fail after upgrade with unknown-worker errors.
    execute("""
    DELETE FROM platform.oban_jobs
    WHERE worker IN (#{Enum.map_join(@retired_workers, ", ", &"'#{&1}'")})
      AND state IN ('available', 'scheduled', 'retryable')
    """)
  end

  # The cold tier is gone from the code, so there is nothing to restore.
  def down, do: :ok
end
