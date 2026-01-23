defmodule ServiceRadar.Repo.Migrations.AddInterfaceMetricGroups do
  @moduledoc """
  Adds metric_groups column to interface_settings for composite chart groupings.
  """
  use Ecto.Migration

  def up do
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'interface_settings'
        AND column_name = 'metric_groups'
      ) THEN
        ALTER TABLE interface_settings
        ADD COLUMN metric_groups jsonb NOT NULL DEFAULT '[]'::jsonb;
      END IF;
    END $$;
    """
  end

  def down do
    alter table(:interface_settings) do
      remove_if_exists :metric_groups, :jsonb
    end
  end
end
