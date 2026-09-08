defmodule ServiceRadar.Repo.Migrations.AddPartitionToDiscoveredInterfaces do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = '#{prefix() || "platform"}'
          AND table_name = 'discovered_interfaces'
          AND column_name = 'partition'
      ) THEN
        ALTER TABLE #{prefix() || "platform"}.discovered_interfaces
          ADD COLUMN partition text DEFAULT 'default';
      END IF;
    END $$;
    """)
  end

  def down do
    execute("""
    ALTER TABLE #{prefix() || "platform"}.discovered_interfaces
      DROP COLUMN IF EXISTS partition
    """)
  end
end
