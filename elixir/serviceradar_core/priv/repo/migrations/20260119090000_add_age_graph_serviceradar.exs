defmodule ServiceRadar.Repo.Migrations.AddAgeGraphServiceradar do
  @moduledoc """
  Ensures the canonical AGE graph exists for topology projections.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      BEGIN
        EXECUTE 'LOAD ''age''';
      EXCEPTION
        WHEN insufficient_privilege THEN
          IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age') THEN
            RAISE NOTICE 'Skipping LOAD ''age'' due to insufficient privilege; AGE extension already exists.';
          ELSE
            RAISE;
          END IF;
      END;
    END
    $$;
    """)

    execute("""
    DO $$
    DECLARE
      graph_exists boolean;
      attempts integer := 0;
    BEGIN
      PERFORM set_config('search_path', 'ag_catalog,platform,"$user",public', true);

      SELECT EXISTS(
        SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'serviceradar'
      ) INTO graph_exists;

      IF NOT graph_exists THEN
        WHILE attempts < 3 AND NOT graph_exists LOOP
          attempts := attempts + 1;

          BEGIN
            PERFORM ag_catalog.create_graph('serviceradar');
          EXCEPTION
            WHEN duplicate_object OR duplicate_schema OR invalid_schema_name THEN
              NULL;
            WHEN undefined_object THEN
              IF attempts >= 3 THEN
                RAISE;
              END IF;

              PERFORM pg_sleep(0.2);
          END;

          SELECT EXISTS(
            SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'serviceradar'
          ) INTO graph_exists;
        END LOOP;
      END IF;

      IF NOT graph_exists THEN
        RAISE EXCEPTION 'AGE graph "%" is missing after migration', 'serviceradar';
      END IF;
    END
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      PERFORM ag_catalog.drop_graph('serviceradar', true);
    EXCEPTION
      WHEN undefined_object THEN
        NULL;
    END
    $$;
    """)
  end
end
