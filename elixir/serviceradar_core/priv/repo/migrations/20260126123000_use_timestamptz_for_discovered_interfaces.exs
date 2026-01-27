defmodule ServiceRadar.Repo.Migrations.UseTimestamptzForDiscoveredInterfaces do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{prefix()}'
          AND table_name = 'discovered_interfaces'
          AND column_name = 'timestamp'
          AND data_type = 'timestamp without time zone'
      ) THEN
        ALTER TABLE #{prefix()}.discovered_interfaces
          ALTER COLUMN "timestamp"
          TYPE timestamptz
          USING "timestamp" AT TIME ZONE 'UTC';
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{prefix()}'
          AND table_name = 'discovered_interfaces'
          AND column_name = 'created_at'
          AND data_type = 'timestamp without time zone'
      ) THEN
        ALTER TABLE #{prefix()}.discovered_interfaces
          ALTER COLUMN "created_at"
          TYPE timestamptz
          USING "created_at" AT TIME ZONE 'UTC';
      END IF;
    END $$;
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{prefix()}'
          AND table_name = 'discovered_interfaces'
          AND column_name = 'timestamp'
          AND data_type = 'timestamp with time zone'
      ) THEN
        ALTER TABLE #{prefix()}.discovered_interfaces
          ALTER COLUMN "timestamp"
          TYPE timestamp without time zone
          USING "timestamp" AT TIME ZONE 'UTC';
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{prefix()}'
          AND table_name = 'discovered_interfaces'
          AND column_name = 'created_at'
          AND data_type = 'timestamp with time zone'
      ) THEN
        ALTER TABLE #{prefix()}.discovered_interfaces
          ALTER COLUMN "created_at"
          TYPE timestamp without time zone
          USING "created_at" AT TIME ZONE 'UTC';
      END IF;
    END $$;
    """)
  end
end
