defmodule ServiceRadar.Repo.Migrations.AddPgStatStatements do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    EXCEPTION
      WHEN insufficient_privilege THEN
        RAISE NOTICE 'Skipping pg_stat_statements extension creation (insufficient privileges)';
    END
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      DROP EXTENSION IF EXISTS pg_stat_statements;
    EXCEPTION
      WHEN insufficient_privilege THEN
        RAISE NOTICE 'Skipping pg_stat_statements extension drop (insufficient privileges)';
    END
    $$;
    """)
  end
end
