defmodule ServiceRadar.Repo.Migrations.AddAgeGraphServiceradar do
  @moduledoc """
  Ensures the canonical AGE graph exists for topology projections.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      graph_exists boolean;
    BEGIN
      SELECT EXISTS(
        SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'serviceradar'
      ) INTO graph_exists;

      IF NOT graph_exists THEN
        BEGIN
          PERFORM ag_catalog.create_graph('serviceradar');
        EXCEPTION
          WHEN duplicate_object OR duplicate_schema OR invalid_schema_name THEN
            NULL;
        END;
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
