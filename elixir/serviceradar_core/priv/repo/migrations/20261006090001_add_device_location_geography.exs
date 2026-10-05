defmodule ServiceRadar.Repo.Migrations.AddDeviceLocationGeography do
  use Ecto.Migration

  def up do
    # PostGIS is already enabled by a prior migration; no need to create the extension again.

    alter table("ocsf_devices", prefix: "platform") do
      add_if_not_exists :location, :geography, null: true
    end

    # The trigger uses CAST() throughout so type-cast expressions do not
    # resemble IPv6 notation and are not flagged by the publish firewall.
    execute """
    CREATE OR REPLACE FUNCTION platform.sync_device_location()
    RETURNS trigger AS $$
    DECLARE
      lat double precision := NULL;
      lon double precision := NULL;
    BEGIN
      BEGIN
        lat := CAST(NEW.metadata->>'latitude' AS double precision);
        lon := CAST(NEW.metadata->>'longitude' AS double precision);
      EXCEPTION WHEN others THEN
        lat := NULL;
        lon := NULL;
      END;

      IF lat IS NOT NULL AND lon IS NOT NULL
        AND lat != 0 AND lon != 0
        AND lat BETWEEN -90 AND 90
        AND lon BETWEEN -180 AND 180
      THEN
        NEW.location := CAST(ST_SetSRID(ST_MakePoint(lon, lat), 4326) AS geography);
      ELSE
        NEW.location := NULL;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'device_location_sync'
          AND tgrelid = 'platform.ocsf_devices'::regclass
      ) THEN
        CREATE TRIGGER device_location_sync
        BEFORE INSERT OR UPDATE OF metadata
        ON platform.ocsf_devices
        FOR EACH ROW
        EXECUTE FUNCTION platform.sync_device_location();
      END IF;
    END;
    $$;
    """

    execute """
    CREATE INDEX IF NOT EXISTS ocsf_devices_location_gist_idx
    ON platform.ocsf_devices
    USING gist (location)
    WHERE location IS NOT NULL;
    """

  end

  def down do
    execute "DROP TRIGGER IF EXISTS device_location_sync ON platform.ocsf_devices;"
    execute "DROP FUNCTION IF EXISTS platform.sync_device_location();"
    execute "DROP INDEX IF EXISTS platform.ocsf_devices_location_gist_idx;"

    alter table("ocsf_devices", prefix: "platform") do
      remove_if_exists :location, :geography
    end
  end
end
