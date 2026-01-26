defmodule ServiceRadar.Repo.Migrations.EnsureObanPlatformTables do
  @moduledoc """
  Ensures Oban tables exist in the `platform` schema.

  This migration handles multiple scenarios:
  1. Fresh install - no Oban tables anywhere: creates tables in platform schema
  2. Tables in public only: copies structure to platform schema
  3. Tables in platform only: verifies completeness, no-op if complete
  4. Tables in both schemas: uses platform, logs warning

  This is a safety net migration that runs after the main schema migration
  to catch cases where Oban.Migrations.up() created tables in the wrong schema.
  """
  use Ecto.Migration

  require Logger

  @platform_schema "platform"

  def up do
    # Ensure platform schema exists
    execute("CREATE SCHEMA IF NOT EXISTS #{@platform_schema}")

    platform_jobs = table_exists?("#{@platform_schema}.oban_jobs")
    public_jobs = table_exists?("public.oban_jobs")

    log_info("Checking Oban tables - platform: #{platform_jobs}, public: #{public_jobs}")

    cond do
      platform_jobs and public_jobs ->
        # Both exist - use platform, ensure it's complete
        log_info("Oban tables exist in both schemas; ensuring platform schema is complete")
        ensure_platform_oban_complete()

      platform_jobs ->
        # Only platform exists - ensure complete
        log_info("Oban tables exist in platform schema; verifying completeness")
        ensure_platform_oban_complete()

      public_jobs ->
        # Only public exists - migrate to platform
        log_info("Oban tables exist in public schema only; migrating to platform")
        migrate_oban_to_platform()

      true ->
        # Neither exists - create fresh in platform
        log_info("No Oban tables found; creating in platform schema")
        create_oban_in_platform()
    end
  end

  def down do
    # This migration is a safety net; rolling back is a no-op
    # to preserve data integrity
    :ok
  end

  # Create fresh Oban tables in platform schema
  defp create_oban_in_platform do
    # Use Oban's official migration with explicit prefix
    Oban.Migrations.up(prefix: @platform_schema)
  end

  # Migrate Oban tables from public to platform schema
  defp migrate_oban_to_platform do
    # Create sequence for job IDs
    execute("CREATE SEQUENCE IF NOT EXISTS #{@platform_schema}.oban_jobs_id_seq")

    # Create oban_jobs table with same structure as public
    execute("""
    CREATE TABLE IF NOT EXISTS #{@platform_schema}.oban_jobs (
      LIKE public.oban_jobs INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES
    )
    """)

    # Link sequence to the new table's id column
    execute("""
    ALTER TABLE #{@platform_schema}.oban_jobs
      ALTER COLUMN id SET DEFAULT nextval('#{@platform_schema}.oban_jobs_id_seq'::regclass)
    """)

    execute("ALTER SEQUENCE #{@platform_schema}.oban_jobs_id_seq OWNED BY #{@platform_schema}.oban_jobs.id")

    # Create oban_peers table (used by Oban.Peers.Database)
    create_oban_peers_table()

    log_info("Migrated Oban tables from public to platform schema")
  end

  # Ensure all required Oban objects exist in platform schema
  defp ensure_platform_oban_complete do
    # Ensure sequence exists and is linked
    execute("CREATE SEQUENCE IF NOT EXISTS #{@platform_schema}.oban_jobs_id_seq")

    # Only alter if the table exists and doesn't already have the default
    if table_exists?("#{@platform_schema}.oban_jobs") do
      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_attrdef ad
          JOIN pg_class c ON ad.adrelid = c.oid
          JOIN pg_namespace n ON c.relnamespace = n.oid
          WHERE n.nspname = '#{@platform_schema}'
            AND c.relname = 'oban_jobs'
            AND ad.adnum = (
              SELECT attnum FROM pg_attribute
              WHERE attrelid = c.oid AND attname = 'id'
            )
        ) THEN
          ALTER TABLE #{@platform_schema}.oban_jobs
            ALTER COLUMN id SET DEFAULT nextval('#{@platform_schema}.oban_jobs_id_seq'::regclass);
        END IF;
      END $$;
      """)

      execute("""
      DO $$
      BEGIN
        ALTER SEQUENCE #{@platform_schema}.oban_jobs_id_seq OWNED BY #{@platform_schema}.oban_jobs.id;
      EXCEPTION WHEN others THEN
        -- Sequence may already be owned, ignore error
        NULL;
      END $$;
      """)
    end

    # Ensure oban_peers table exists
    create_oban_peers_table()

    log_info("Verified Oban tables complete in platform schema")
  end

  # Create the oban_peers table used by Oban.Peers.Database
  defp create_oban_peers_table do
    execute("""
    CREATE UNLOGGED TABLE IF NOT EXISTS #{@platform_schema}.oban_peers (
      name text NOT NULL,
      node text NOT NULL,
      started_at timestamp without time zone NOT NULL,
      expires_at timestamp without time zone NOT NULL,
      PRIMARY KEY (name)
    )
    """)
  end

  # Check if a table exists (schema.table format)
  defp table_exists?(qualified_name) do
    %{rows: [[value]]} = repo().query!("SELECT to_regclass($1)", [qualified_name])
    value != nil
  end

  defp log_info(msg) do
    # Use repo's telemetry or fall back to IO
    if function_exported?(Logger, :info, 1) do
      Logger.info("[EnsureObanPlatformTables] #{msg}")
    else
      IO.puts("[EnsureObanPlatformTables] #{msg}")
    end
  end
end
