defmodule ServiceRadar.Repo.Migrations.UsePlatformAgeGraph do
  @moduledoc """
  Ensures the canonical AGE graph lives in a dedicated schema and removes legacy graphs.
  """

  use Ecto.Migration

  def up do
    execute("LOAD 'age'")

    execute("""
    DO $$
    DECLARE
      graph_exists boolean;
      graph_name text := 'platform_graph';
      attempts integer := 0;
    BEGIN
      PERFORM set_config('search_path', 'ag_catalog,"$user",public', true);

      SELECT EXISTS(SELECT 1 FROM ag_catalog.ag_graph WHERE name = graph_name) INTO graph_exists;
      IF NOT graph_exists THEN
        WHILE attempts < 3 AND NOT graph_exists LOOP
          attempts := attempts + 1;

          BEGIN
            PERFORM ag_catalog.create_graph(graph_name);
          EXCEPTION
            WHEN duplicate_schema THEN
              RAISE EXCEPTION 'Schema % already exists; cannot create AGE graph. Drop or rename the schema before retrying.', graph_name;
            WHEN duplicate_object OR invalid_schema_name THEN
              NULL;
            WHEN undefined_object THEN
              IF attempts >= 3 THEN
                RAISE;
              END IF;

              PERFORM pg_sleep(0.2);
          END;

          SELECT EXISTS(SELECT 1 FROM ag_catalog.ag_graph WHERE name = graph_name) INTO graph_exists;
        END LOOP;
      END IF;

      SELECT EXISTS(SELECT 1 FROM ag_catalog.ag_graph WHERE name = graph_name) INTO graph_exists;
      IF NOT graph_exists THEN
        RAISE EXCEPTION 'AGE graph "%" is missing after migration', graph_name;
      END IF;
    END
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'platform_graph') THEN
        PERFORM ag_catalog.drop_graph('platform_graph', true);
      END IF;
    END
    $$;
    """)
  end
end
