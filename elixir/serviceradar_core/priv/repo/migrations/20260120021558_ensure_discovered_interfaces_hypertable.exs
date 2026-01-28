defmodule ServiceRadar.Repo.Migrations.EnsureDiscoveredInterfacesHypertable do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      table_ident text;
    BEGIN
      table_ident := format('%I.%I', '#{prefix()}', 'discovered_interfaces');

      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb')
         AND EXISTS (
           SELECT 1
           FROM pg_tables
           WHERE schemaname = '#{prefix()}'
             AND tablename = 'discovered_interfaces'
         ) THEN
        EXECUTE format(
          'SELECT public.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
          table_ident,
          'timestamp'
        );

        EXECUTE format(
          'SELECT public.add_retention_policy(%L::regclass, INTERVAL ''3 days'', if_not_exists => true)',
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
    BEGIN
      table_ident := format('%I.%I', '#{prefix()}', 'discovered_interfaces');

      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
        EXECUTE format(
          'SELECT public.remove_retention_policy(%L::regclass, if_exists => true)',
          table_ident
        );
      END IF;
    END
    $$;
    """)
  end
end
