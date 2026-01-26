defmodule ServiceRadar.Repo.Migrations.EnsureDiscoveredInterfacesHypertable do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      table_ident text;
    BEGIN
      table_ident := format('%I.%I', '#{prefix()}', 'discovered_interfaces');

      EXECUTE format(
        'SELECT public.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
        table_ident,
        'timestamp'
      );

      EXECUTE format(
        'SELECT public.add_retention_policy(%L::regclass, INTERVAL ''3 days'', if_not_exists => true)',
        table_ident
      );
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

      EXECUTE format(
        'SELECT public.remove_retention_policy(%L::regclass, if_exists => true)',
        table_ident
      );
    END
    $$;
    """)
  end
end
