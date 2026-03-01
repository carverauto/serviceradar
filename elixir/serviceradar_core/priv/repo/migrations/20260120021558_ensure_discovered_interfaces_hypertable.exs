defmodule ServiceRadar.Repo.Migrations.EnsureDiscoveredInterfacesHypertable do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', '#{prefix() || "platform"}', 'discovered_interfaces');
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM pg_proc p
           JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE p.proname = 'create_hypertable'
             AND n.nspname = ts_schema
         )
         AND EXISTS (
           SELECT 1
           FROM pg_tables
           WHERE schemaname = '#{prefix() || "platform"}'
             AND tablename = 'discovered_interfaces'
         ) THEN
        EXECUTE format(
          'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
          ts_schema,
          table_ident,
          'timestamp'
        );

        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''3 days'', if_not_exists => true)',
          ts_schema,
          table_ident
        );
      END IF;
    END
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', '#{prefix() || "platform"}', 'discovered_interfaces');
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL THEN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );
      END IF;
    END
    $$;
    """)
  end
end
