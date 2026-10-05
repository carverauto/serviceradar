defmodule ServiceRadar.Repo.Migrations.MarkSourceRetiredDevices do
  @moduledoc """
  Keeps the `source_retired` mark consistent (change `add-source-id-succession`, design D5).

  A live record left holding only retired source ids is marked: `ocsf_devices.source_retired_at`
  is set, and the record is hidden from default device reads and inventory counts until the
  grace pass soft-deletes it. Three rules hold the mark to its definition whichever writer
  touches the row:

  * `metadata.identity_state` mirrors the mark: `"source_retired"` while `source_retired_at` is
    set, removed when it clears. Readers of `identity_state` see the mark without reading the
    column.
  * A soft delete clears the mark, so a tombstone is never marked, and a record an operator
    restores comes back unmarked.
  * Registering an agent identifier or a source-authoritative identifier (`armis_device_id`,
    `netbox_device_id`) on a marked record clears its mark in the statement that registers it:
    the record is no longer retired-only. MAC and address evidence registers neither, so it
    never clears the mark. The identifier types are listed here; a new source-authoritative
    type must be added to `trg_device_identifiers_clear_source_retired`.

  The inventory rollups count a marked record as inactive: `trg_ocsf_devices_inventory_rollup`
  and `refresh_device_inventory_rollups` read active as `deleted_at IS NULL AND
  source_retired_at IS NULL`. No record is marked before this migration, so the stored counts
  stay correct without a refresh.

  Also `platform.device_held_for_review(uid)`: whether an open de-duplication task names the
  device. The grace pass does not delete a held record, and its candidate read and its soft
  delete's WHERE clause both use this one definition.

  Schema only: no existing row is rewritten.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.trg_ocsf_devices_source_retired_mirror()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.deleted_at IS NOT NULL THEN
        NEW.source_retired_at := NULL;
      END IF;

      IF NEW.source_retired_at IS NOT NULL THEN
        NEW.metadata := COALESCE(NEW.metadata, '{}'::jsonb) ||
          jsonb_build_object('identity_state', 'source_retired');
      ELSIF NEW.metadata ->> 'identity_state' = 'source_retired' THEN
        NEW.metadata := NEW.metadata - 'identity_state';
      END IF;

      RETURN NEW;
    END;
    $$;
    """)

    # WHEN-guarded so plpgsql is entered only for a row that is marked or claims to be.
    execute("""
    CREATE TRIGGER trg_ocsf_devices_source_retired_mirror
    BEFORE INSERT OR UPDATE ON #{@prefix}.ocsf_devices
    FOR EACH ROW
    WHEN (NEW.source_retired_at IS NOT NULL OR NEW.metadata ->> 'identity_state' = 'source_retired')
    EXECUTE FUNCTION #{@prefix}.trg_ocsf_devices_source_retired_mirror()
    """)

    # One function for both statement triggers: a trigger with transition tables names one
    # event, and both name their new rows `registered`. The partial index on marked live
    # records makes the common case, nothing marked, one empty index probe.
    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.trg_device_identifiers_clear_source_retired()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{@prefix}.ocsf_devices
        WHERE source_retired_at IS NOT NULL AND deleted_at IS NULL
      ) THEN
        UPDATE #{@prefix}.ocsf_devices AS d
        SET source_retired_at = NULL
        WHERE d.source_retired_at IS NOT NULL
          AND d.deleted_at IS NULL
          AND EXISTS (
            SELECT 1 FROM registered AS r
            WHERE r.device_id = d.uid
              AND r.identifier_type IN ('agent_id', 'armis_device_id', 'netbox_device_id')
          );
      END IF;

      RETURN NULL;
    END;
    $$;
    """)

    execute("""
    CREATE TRIGGER trg_device_identifiers_clear_source_retired_insert
    AFTER INSERT ON #{@prefix}.device_identifiers
    REFERENCING NEW TABLE AS registered
    FOR EACH STATEMENT
    EXECUTE FUNCTION #{@prefix}.trg_device_identifiers_clear_source_retired()
    """)

    execute("""
    CREATE TRIGGER trg_device_identifiers_clear_source_retired_update
    AFTER UPDATE ON #{@prefix}.device_identifiers
    REFERENCING NEW TABLE AS registered
    FOR EACH STATEMENT
    EXECUTE FUNCTION #{@prefix}.trg_device_identifiers_clear_source_retired()
    """)

    execute(refresh_rollups_sql("deleted_at IS NULL AND source_retired_at IS NULL"))

    execute(
      rollup_trigger_sql(
        "OLD.deleted_at IS NULL AND OLD.source_retired_at IS NULL",
        "NEW.deleted_at IS NULL AND NEW.source_retired_at IS NULL"
      )
    )

    # identity_deduplication_tasks_device_uids_gin_idx serves the containment test.
    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.device_held_for_review(device_uid text)
    RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
      SELECT EXISTS (
        SELECT 1 FROM #{@prefix}.identity_deduplication_tasks AS t
        WHERE t.status = 'open' AND t.device_uids @> ARRAY[device_uid]
      )
    $$
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS #{@prefix}.device_held_for_review(text)")
    execute(refresh_rollups_sql("deleted_at IS NULL"))
    execute(rollup_trigger_sql("OLD.deleted_at IS NULL", "NEW.deleted_at IS NULL"))

    execute("""
    DROP TRIGGER IF EXISTS trg_device_identifiers_clear_source_retired_update
      ON #{@prefix}.device_identifiers
    """)

    execute("""
    DROP TRIGGER IF EXISTS trg_device_identifiers_clear_source_retired_insert
      ON #{@prefix}.device_identifiers
    """)

    execute("DROP FUNCTION IF EXISTS #{@prefix}.trg_device_identifiers_clear_source_retired()")

    execute("""
    DROP TRIGGER IF EXISTS trg_ocsf_devices_source_retired_mirror ON #{@prefix}.ocsf_devices
    """)

    execute("DROP FUNCTION IF EXISTS #{@prefix}.trg_ocsf_devices_source_retired_mirror()")
  end

  # The bodies of `20260306001000_optimize_device_inventory_rollup_bulk_sync` with the active
  # predicate as a parameter; `down/0` passes the original one.
  defp refresh_rollups_sql(active) do
    """
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
      WHERE #{active};

      INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
      SELECT 'available', COUNT(*)::bigint, now()
      FROM #{@prefix}.ocsf_devices
      WHERE #{active}
        AND COALESCE(is_available, false) = true;

      INSERT INTO #{@prefix}.device_inventory_counts (key, value, updated_at)
      SELECT 'unavailable', COUNT(*)::bigint, now()
      FROM #{@prefix}.ocsf_devices
      WHERE #{active}
        AND COALESCE(is_available, false) = false;

      INSERT INTO #{@prefix}.device_inventory_type_counts (type, count, updated_at)
      SELECT COALESCE(NULLIF(trim(type), ''), 'Unknown') AS type,
             COUNT(*)::bigint AS count,
             now()
      FROM #{@prefix}.ocsf_devices
      WHERE #{active}
      GROUP BY COALESCE(NULLIF(trim(type), ''), 'Unknown');

      INSERT INTO #{@prefix}.device_inventory_vendor_counts (vendor_name, count, updated_at)
      SELECT COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown') AS vendor_name,
             COUNT(*)::bigint AS count,
             now()
      FROM #{@prefix}.ocsf_devices
      WHERE #{active}
      GROUP BY COALESCE(NULLIF(trim(vendor_name), ''), 'Unknown');
    END;
    $$;
    """
  end

  defp rollup_trigger_sql(old_active, new_active) do
    """
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
        old_active := #{old_active};
        old_available := COALESCE(OLD.is_available, false);
        old_type_key := COALESCE(NULLIF(trim(OLD.type), ''), 'Unknown');
        old_vendor_key := COALESCE(NULLIF(trim(OLD.vendor_name), ''), 'Unknown');
      END IF;

      IF TG_OP <> 'DELETE' THEN
        new_active := #{new_active};
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
    """
  end
end
