defmodule ServiceRadar.Repo.Migrations.OptimizeDeviceInventoryRollupBulkSync do
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.refresh_device_inventory_rollups()
    RETURNS void
    LANGUAGE plpgsql
    AS $$
    BEGIN
      TRUNCATE TABLE #{@prefix}.device_inventory_counts;
      TRUNCATE TABLE #{@prefix}.device_inventory_type_counts;
      TRUNCATE TABLE #{@prefix}.device_inventory_vendor_counts;

      INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
      SELECT 'total', COUNT(*)::bigint, now()
      FROM #{@prefix}.ocsf_devices
      WHERE deleted_at IS NULL;

      INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
      SELECT 'available', COUNT(*)::bigint, now()
      FROM #{@prefix}.ocsf_devices
      WHERE deleted_at IS NULL
        AND COALESCE(is_available, false) = true;

      INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
      SELECT 'unavailable', COUNT(*)::bigint, now()
      FROM #{@prefix}.ocsf_devices
      WHERE deleted_at IS NULL
        AND COALESCE(is_available, false) = false;

      INSERT INTO #{@prefix}.device_inventory_type_counts (type, count, updated_at)
      SELECT COALESCE(NULLIF(trim(type), ''), 'Unknown') AS type,
             COUNT(*)::bigint AS count,
             now()
      FROM #{@prefix}.ocsf_devices
      WHERE deleted_at IS NULL
      GROUP BY COALESCE(NULLIF(trim(type), ''), 'Unknown');

      INSERT INTO #{@prefix}.device_inventory_vendor_counts (vendor_name, count, updated_at)
      SELECT COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown') AS vendor_name,
             COUNT(*)::bigint AS count,
             now()
      FROM #{@prefix}.ocsf_devices
      WHERE deleted_at IS NULL
      GROUP BY COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown');
    END;
    $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.trg_ocsf_devices_inventory_rollup()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      old_active boolean := false;
      new_active boolean := false;
      old_available boolean := false;
      new_available boolean := false;
      old_type_key text := NULL;
      new_type_key text := NULL;
      old_vendor_key text := NULL;
      new_vendor_key text := NULL;
    BEGIN
      IF current_setting('platform.skip_inventory_rollup', true) = 'on' THEN
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;

        RETURN NEW;
      END IF;

      IF TG_OP <> 'INSERT' THEN
        old_active := OLD.deleted_at IS NULL;
        old_available := COALESCE(OLD.is_available, false);
        old_type_key := COALESCE(NULLIF(trim(OLD.type), ''), 'Unknown');
        old_vendor_key := COALESCE(NULLIF(trim(OLD.vendor_name), ''), 'Unknown');
      END IF;

      IF TG_OP <> 'DELETE' THEN
        new_active := NEW.deleted_at IS NULL;
        new_available := COALESCE(NEW.is_available, false);
        new_type_key := COALESCE(NULLIF(trim(NEW.type), ''), 'Unknown');
        new_vendor_key := COALESCE(NULLIF(trim(NEW.vendor_name), ''), 'Unknown');
      END IF;

      IF TG_OP = 'UPDATE' THEN
        IF old_active = new_active AND old_available = new_available THEN
          IF old_active AND (old_type_key <> new_type_key OR old_vendor_key <> new_vendor_key) THEN
            PERFORM #{@prefix}.update_device_inventory_counts_row(
              0,
              0,
              0,
              OLD.type,
              OLD.vendor_name,
              -1
            );

            PERFORM #{@prefix}.update_device_inventory_counts_row(
              0,
              0,
              0,
              NEW.type,
              NEW.vendor_name,
              1
            );
          END IF;

          RETURN NEW;
        END IF;
      END IF;

      IF old_active THEN
        PERFORM #{@prefix}.update_device_inventory_counts_row(
          -1,
          CASE WHEN old_available THEN -1 ELSE 0 END,
          CASE WHEN old_available THEN 0 ELSE -1 END,
          OLD.type,
          OLD.vendor_name,
          -1
        );
      END IF;

      IF new_active THEN
        PERFORM #{@prefix}.update_device_inventory_counts_row(
          1,
          CASE WHEN new_available THEN 1 ELSE 0 END,
          CASE WHEN new_available THEN 0 ELSE 1 END,
          NEW.type,
          NEW.vendor_name,
          1
        );
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    END;
    $$;
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.trg_ocsf_devices_inventory_rollup()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      old_active boolean := false;
      new_active boolean := false;
      old_available boolean := false;
      new_available boolean := false;
      old_type_key text := NULL;
      new_type_key text := NULL;
      old_vendor_key text := NULL;
      new_vendor_key text := NULL;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        old_active := OLD.deleted_at IS NULL;
        old_available := COALESCE(OLD.is_available, false);
        old_type_key := COALESCE(NULLIF(trim(OLD.type), ''), 'Unknown');
        old_vendor_key := COALESCE(NULLIF(trim(OLD.vendor_name), ''), 'Unknown');
      END IF;

      IF TG_OP <> 'DELETE' THEN
        new_active := NEW.deleted_at IS NULL;
        new_available := COALESCE(NEW.is_available, false);
        new_type_key := COALESCE(NULLIF(trim(NEW.type), ''), 'Unknown');
        new_vendor_key := COALESCE(NULLIF(trim(NEW.vendor_name), ''), 'Unknown');
      END IF;

      IF TG_OP = 'UPDATE' THEN
        IF old_active = new_active AND old_available = new_available THEN
          IF old_active AND (old_type_key <> new_type_key OR old_vendor_key <> new_vendor_key) THEN
            PERFORM #{@prefix}.update_device_inventory_counts_row(
              0,
              0,
              0,
              OLD.type,
              OLD.vendor_name,
              -1
            );

            PERFORM #{@prefix}.update_device_inventory_counts_row(
              0,
              0,
              0,
              NEW.type,
              NEW.vendor_name,
              1
            );
          END IF;

          RETURN NEW;
        END IF;
      END IF;

      IF old_active THEN
        PERFORM #{@prefix}.update_device_inventory_counts_row(
          -1,
          CASE WHEN old_available THEN -1 ELSE 0 END,
          CASE WHEN old_available THEN 0 ELSE -1 END,
          OLD.type,
          OLD.vendor_name,
          -1
        );
      END IF;

      IF new_active THEN
        PERFORM #{@prefix}.update_device_inventory_counts_row(
          1,
          CASE WHEN new_available THEN 1 ELSE 0 END,
          CASE WHEN new_available THEN 0 ELSE 1 END,
          NEW.type,
          NEW.vendor_name,
          1
        );
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    END;
    $$;
    """)

    execute("DROP FUNCTION IF EXISTS #{@prefix}.refresh_device_inventory_rollups()")
  end
end
