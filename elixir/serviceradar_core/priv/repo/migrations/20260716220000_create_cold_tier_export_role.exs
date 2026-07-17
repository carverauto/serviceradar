defmodule ServiceRadar.Repo.Migrations.CreateColdTierExportRole do
  @moduledoc """
  Read-only export role on the primary for the cold-tier analytics head
  (OpenSpec add-tiered-telemetry-offload, task 1.6; design D6).

  The analytics head reads hot rows through `postgres_fdw` as this role — it
  is the ONLY path from the head into the primary, so it is scoped to
  SELECT on the registry tables plus the cold-tier manifest, and carries
  role-level timeouts so a hung export can never pin a snapshot forever
  (each export COPY holds `backend_xmin` for its whole runtime — verified in
  spike 0.2).

  Grants and settings live here (schema concerns); the password lives in the
  deployment (CNPG `managed.roles` or the compose profile), so this migration
  only sets one when `SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD` is present
  — which is how the local compose/dev loop bootstraps it.

  Idempotent and safe on deployments that never enable the cold tier: the
  role exists but nothing connects as it.
  """

  use Ecto.Migration

  @role "cold_reader"

  # Keep in sync with ServiceRadar.ColdTier.Registry (the registry drift test
  # covers columns; this list covers grants).
  @registry_tables ~w(
    logs
    otel_traces
    otel_metrics
    otel_metric_points
    timeseries_metrics
    ocsf_events
    ocsf_network_activity
  )

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
        CREATE ROLE #{@role} LOGIN;
      END IF;
    END $$;
    """)

    # Read-only scope: usage on the schema, SELECT on registry tables + the
    # manifest. No writes, no other tables.
    execute("GRANT USAGE ON SCHEMA platform TO #{@role}")

    for table <- @registry_tables do
      execute("""
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.tables
          WHERE table_schema = 'platform' AND table_name = '#{table}'
        ) THEN
          EXECUTE 'GRANT SELECT ON platform.#{table} TO #{@role}';
        END IF;
      END $$;
      """)
    end

    for table <- ~w(cold_chunk_exports cold_tier_boundaries) do
      execute("""
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.tables
          WHERE table_schema = 'platform' AND table_name = '#{table}'
        ) THEN
          EXECUTE 'GRANT SELECT ON platform.#{table} TO #{@role}';
        END IF;
      END $$;
      """)
    end

    # TimescaleDB keeps chunk relations in an internal schema; postgres_fdw
    # reads the hypertable parent, but the planner still touches the chunks.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = '_timescaledb_internal') THEN
        EXECUTE 'GRANT USAGE ON SCHEMA _timescaledb_internal TO #{@role}';
        EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_internal TO #{@role}';
        EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA _timescaledb_internal GRANT SELECT ON TABLES TO #{@role}';
      END IF;
    END $$;
    """)

    # Role-level bounds: a stuck export must not pin the vacuum horizon or
    # hold a connection forever. Export units are chunk-sized (seconds to
    # tens of seconds); these are generous ceilings, not tuning knobs.
    execute("ALTER ROLE #{@role} SET statement_timeout = '300s'")
    execute("ALTER ROLE #{@role} SET idle_in_transaction_session_timeout = '120s'")
    execute("ALTER ROLE #{@role} SET lock_timeout = '10s'")

    case System.get_env("SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD") do
      password when is_binary(password) and password != "" ->
        execute("ALTER ROLE #{@role} PASSWORD '#{String.replace(password, "'", "''")}'")

      _ ->
        :ok
    end
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
        EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA platform FROM #{@role}';
        EXECUTE 'REVOKE ALL ON SCHEMA platform FROM #{@role}';
        IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = '_timescaledb_internal') THEN
          EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA _timescaledb_internal FROM #{@role}';
          EXECUTE 'REVOKE ALL ON SCHEMA _timescaledb_internal FROM #{@role}';
        END IF;
        DROP ROLE #{@role};
      END IF;
    END $$;
    """)
  end
end
