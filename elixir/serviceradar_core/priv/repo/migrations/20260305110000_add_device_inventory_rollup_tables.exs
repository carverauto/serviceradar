defmodule ServiceRadar.Repo.Migrations.AddDeviceInventoryRollupTables do
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{@prefix}.device_inventory_counts (
      key text PRIMARY KEY,
      value bigint NOT NULL DEFAULT 0,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{@prefix}.device_inventory_type_counts (
      type text PRIMARY KEY,
      count bigint NOT NULL DEFAULT 0,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{@prefix}.device_inventory_vendor_counts (
      vendor_name text PRIMARY KEY,
      count bigint NOT NULL DEFAULT 0,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS device_inventory_type_counts_count_idx
      ON #{@prefix}.device_inventory_type_counts (count DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS device_inventory_vendor_counts_count_idx
      ON #{@prefix}.device_inventory_vendor_counts (count DESC)
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.update_device_inventory_counts_row(
      p_total_delta bigint,
      p_available_delta bigint,
      p_unavailable_delta bigint,
      p_type text,
      p_vendor text,
      p_dim_delta bigint
    ) RETURNS void
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF p_total_delta <> 0 THEN
        INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
        VALUES ('total', p_total_delta, now())
        ON CONFLICT (key) DO UPDATE
          SET value = #{@prefix}.device_inventory_counts.value + EXCLUDED.value,
              updated_at = now();
      END IF;

      IF p_available_delta <> 0 THEN
        INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
        VALUES ('available', p_available_delta, now())
        ON CONFLICT (key) DO UPDATE
          SET value = #{@prefix}.device_inventory_counts.value + EXCLUDED.value,
              updated_at = now();
      END IF;

      IF p_unavailable_delta <> 0 THEN
        INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
        VALUES ('unavailable', p_unavailable_delta, now())
        ON CONFLICT (key) DO UPDATE
          SET value = #{@prefix}.device_inventory_counts.value + EXCLUDED.value,
              updated_at = now();
      END IF;

      IF p_dim_delta <> 0 THEN
        INSERT INTO #{@prefix}.device_inventory_type_counts (type, count, updated_at)
        VALUES (COALESCE(NULLIF(trim(p_type), ''), 'Unknown'), p_dim_delta, now())
        ON CONFLICT (type) DO UPDATE
          SET count = #{@prefix}.device_inventory_type_counts.count + EXCLUDED.count,
              updated_at = now();

        DELETE FROM #{@prefix}.device_inventory_type_counts WHERE count <= 0;

        INSERT INTO #{@prefix}.device_inventory_vendor_counts (vendor_name, count, updated_at)
        VALUES (COALESCE(NULLIF(trim(p_vendor), ''), 'Unknown'), p_dim_delta, now())
        ON CONFLICT (vendor_name) DO UPDATE
          SET count = #{@prefix}.device_inventory_vendor_counts.count + EXCLUDED.count,
              updated_at = now();

        DELETE FROM #{@prefix}.device_inventory_vendor_counts WHERE count <= 0;
      END IF;
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
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        old_active := OLD.deleted_at IS NULL;
        old_available := COALESCE(OLD.is_available, false);
      END IF;

      IF TG_OP <> 'DELETE' THEN
        new_active := NEW.deleted_at IS NULL;
        new_available := COALESCE(NEW.is_available, false);
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

    execute("""
    DROP TRIGGER IF EXISTS trg_ocsf_devices_inventory_rollup ON #{@prefix}.ocsf_devices
    """)

    execute("""
    CREATE TRIGGER trg_ocsf_devices_inventory_rollup
    AFTER INSERT OR UPDATE OR DELETE ON #{@prefix}.ocsf_devices
    FOR EACH ROW
    EXECUTE FUNCTION #{@prefix}.trg_ocsf_devices_inventory_rollup()
    """)

    execute("""
    TRUNCATE TABLE #{@prefix}.device_inventory_counts
    """)

    execute("""
    TRUNCATE TABLE #{@prefix}.device_inventory_type_counts
    """)

    execute("""
    TRUNCATE TABLE #{@prefix}.device_inventory_vendor_counts
    """)

    execute("""
    INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
    SELECT 'total', COUNT(*)::bigint, now()
    FROM #{@prefix}.ocsf_devices
    WHERE deleted_at IS NULL
    ON CONFLICT (key) DO UPDATE
      SET value = EXCLUDED.value,
          updated_at = now()
    """)

    execute("""
    INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
    SELECT 'available', COUNT(*)::bigint, now()
    FROM #{@prefix}.ocsf_devices
    WHERE deleted_at IS NULL
      AND COALESCE(is_available, false) = true
    ON CONFLICT (key) DO UPDATE
      SET value = EXCLUDED.value,
          updated_at = now()
    """)

    execute("""
    INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
    SELECT 'unavailable', COUNT(*)::bigint, now()
    FROM #{@prefix}.ocsf_devices
    WHERE deleted_at IS NULL
      AND COALESCE(is_available, false) = false
    ON CONFLICT (key) DO UPDATE
      SET value = EXCLUDED.value,
          updated_at = now()
    """)

    execute("""
    INSERT INTO #{@prefix}.device_inventory_type_counts (type, count, updated_at)
    SELECT COALESCE(NULLIF(trim(type), ''), 'Unknown') AS type,
           COUNT(*)::bigint AS count,
           now()
    FROM #{@prefix}.ocsf_devices
    WHERE deleted_at IS NULL
    GROUP BY COALESCE(NULLIF(trim(type), ''), 'Unknown')
    """)

    execute("""
    INSERT INTO #{@prefix}.device_inventory_vendor_counts (vendor_name, count, updated_at)
    SELECT COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown') AS vendor_name,
           COUNT(*)::bigint AS count,
           now()
    FROM #{@prefix}.ocsf_devices
    WHERE deleted_at IS NULL
    GROUP BY COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown')
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS trg_ocsf_devices_inventory_rollup ON #{@prefix}.ocsf_devices")
    execute("DROP FUNCTION IF EXISTS #{@prefix}.trg_ocsf_devices_inventory_rollup()")

    execute(
      "DROP FUNCTION IF EXISTS #{@prefix}.update_device_inventory_counts_row(bigint, bigint, bigint, text, text, bigint)"
    )

    execute("DROP INDEX IF EXISTS #{@prefix}.device_inventory_type_counts_count_idx")
    execute("DROP INDEX IF EXISTS #{@prefix}.device_inventory_vendor_counts_count_idx")
    execute("DROP TABLE IF EXISTS #{@prefix}.device_inventory_type_counts")
    execute("DROP TABLE IF EXISTS #{@prefix}.device_inventory_vendor_counts")
    execute("DROP TABLE IF EXISTS #{@prefix}.device_inventory_counts")
  end
end
