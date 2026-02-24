defmodule ServiceRadar.Repo.Migrations.AddManagementDeviceId do
  @moduledoc """
  Adds management_device_id to ocsf_devices for management device fallback.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'platform'
          AND table_name = 'ocsf_devices'
          AND column_name = 'management_device_id'
      ) THEN
        ALTER TABLE platform.ocsf_devices
          ADD COLUMN management_device_id text;
      END IF;
    END $$;
    """)
  end

  def down do
    execute("""
    ALTER TABLE platform.ocsf_devices
      DROP COLUMN IF EXISTS management_device_id
    """)
  end
end
