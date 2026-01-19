defmodule ServiceRadar.Repo.Migrations.AddAgeGraphServiceradar do
  @moduledoc """
  Ensures the canonical AGE graph exists for topology projections.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      PERFORM ag_catalog.create_graph('serviceradar');
    EXCEPTION
      WHEN duplicate_object THEN
        NULL;
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
