defmodule ServiceRadar.Repo.Migrations.EnforcePlatformSchemaOwnership do
  @moduledoc """
  Enforces canonical ownership for the `platform` schema.

  This is intentionally idempotent and safe to run repeatedly across
  Helm and Docker Compose deployments.

  We intentionally avoid mass `ALTER ... OWNER` operations on every object here,
  because those require strong relation locks and can stall startup in live
  environments with concurrent writers.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      app_role_exists boolean;
    BEGIN
      SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar')
      INTO app_role_exists;

      IF NOT app_role_exists THEN
        RAISE NOTICE 'Role serviceradar does not exist; skipping platform ownership enforcement';
        RETURN;
      END IF;

      EXECUTE 'CREATE SCHEMA IF NOT EXISTS platform AUTHORIZATION serviceradar';
      EXECUTE 'ALTER SCHEMA platform OWNER TO serviceradar';

      EXECUTE 'GRANT USAGE, CREATE ON SCHEMA platform TO serviceradar';
      EXECUTE 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA platform TO serviceradar';
      EXECUTE 'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA platform TO serviceradar';
      EXECUTE 'GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA platform TO serviceradar';
      EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA platform GRANT ALL ON TABLES TO serviceradar';
      EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA platform GRANT ALL ON SEQUENCES TO serviceradar';
      EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA platform GRANT ALL ON FUNCTIONS TO serviceradar';
    END
    $$;
    """)
  end

  def down do
    :ok
  end
end
