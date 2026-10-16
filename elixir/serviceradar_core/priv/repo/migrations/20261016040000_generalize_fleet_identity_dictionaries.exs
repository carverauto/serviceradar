defmodule ServiceRadar.Repo.Migrations.GeneralizeFleetIdentityDictionaries do
  @moduledoc """
  Expand-only identity storage: rollback disables lifecycle hooks but retains
  assigned numbers, epochs and the widened sequence. Reusing an ID is unsafe.
  Sequence-backed dictionaries and lifecycle triggers are managed explicitly;
  their Ash resources use migrate? false.
  """
  use Ecto.Migration

  # serviceradar:allow-startup-maintenance - updates are inside lifecycle functions;
  # existing inventory is backfilled by bounded FleetIdentity pages, not startup DML.
  def up do
    execute("ALTER TABLE platform.ocsf_devices ADD COLUMN IF NOT EXISTS identity_purged_at timestamp without time zone")

    execute("ALTER SEQUENCE platform.device_fleet_ordinals_ordinal_seq AS bigint MAXVALUE 4294967295 NO CYCLE")
    execute("ALTER TABLE platform.device_fleet_ordinals ALTER COLUMN ordinal TYPE bigint")
    execute("ALTER TABLE platform.device_fleet_ordinals DROP CONSTRAINT IF EXISTS device_fleet_ordinals_u32")
    execute("ALTER TABLE platform.device_fleet_ordinals ADD CONSTRAINT device_fleet_ordinals_u32 CHECK (ordinal BETWEEN 1 AND 4294967295)")

    execute("""
    CREATE TABLE IF NOT EXISTS platform.fleet_dictionary_epochs (
      name text PRIMARY KEY CHECK (name = 'inventory'),
      epoch uuid NOT NULL DEFAULT gen_random_uuid()
    )
    """)

    execute("""
    INSERT INTO platform.fleet_dictionary_epochs (name) VALUES ('inventory') ON CONFLICT (name) DO NOTHING
    """)

    execute("""
    CREATE SEQUENCE IF NOT EXISTS platform.interface_fleet_ordinals_ordinal_seq
      AS bigint MINVALUE 1 MAXVALUE 4294967295 NO CYCLE
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS platform.interface_fleet_ordinals (
      device_uid text NOT NULL REFERENCES platform.ocsf_devices(uid) ON DELETE RESTRICT,
      interface_uid text NOT NULL,
      ordinal bigint NOT NULL DEFAULT nextval('platform.interface_fleet_ordinals_ordinal_seq'),
      tombstoned boolean NOT NULL DEFAULT false,
      allocated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (device_uid, interface_uid),
      CONSTRAINT interface_fleet_ordinals_ordinal_uidx UNIQUE (ordinal),
      CONSTRAINT interface_fleet_ordinals_u32 CHECK (ordinal BETWEEN 1 AND 4294967295)
    )
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.protect_fleet_identity() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE check_violation USING MESSAGE = 'Persistent fleet identities cannot be deleted';
    END;
    $$
    """)

    for table <- ["device_fleet_ordinals", "interface_fleet_ordinals"] do
      execute("DROP TRIGGER IF EXISTS trg_protect_fleet_identity_delete ON platform.#{table}")
      execute("""
      CREATE TRIGGER trg_protect_fleet_identity_delete BEFORE DELETE ON platform.#{table}
      FOR EACH ROW EXECUTE FUNCTION platform.protect_fleet_identity()
      """)
      execute("DROP TRIGGER IF EXISTS trg_protect_fleet_identity_truncate ON platform.#{table}")
      execute("""
      CREATE TRIGGER trg_protect_fleet_identity_truncate BEFORE TRUNCATE ON platform.#{table}
      FOR EACH STATEMENT EXECUTE FUNCTION platform.protect_fleet_identity()
      """)
    end

    execute("""
    CREATE OR REPLACE FUNCTION platform.ensure_device_fleet_ordinal(p_uid text) RETURNS bigint
    LANGUAGE plpgsql AS $$
    DECLARE
      live boolean;
      assigned bigint;
    BEGIN
      -- Serialize allocation with all canonical writes, including raw bulk upserts.
      SELECT deleted_at IS NULL AND COALESCE(is_active, true)
        AND COALESCE(deleted_reason, '') <> 'merged'
      INTO live FROM platform.ocsf_devices WHERE uid = p_uid FOR NO KEY UPDATE;
      IF NOT FOUND THEN RETURN NULL; END IF;

      SELECT ordinal INTO assigned FROM platform.device_fleet_ordinals WHERE uid = p_uid;
      IF assigned IS NOT NULL THEN
        UPDATE platform.device_fleet_ordinals SET tombstoned = NOT live
          WHERE uid = p_uid AND tombstoned IS DISTINCT FROM NOT live;
      ELSIF live THEN
        INSERT INTO platform.device_fleet_ordinals(uid) VALUES (p_uid)
          RETURNING ordinal INTO assigned;
      END IF;
      IF live THEN RETURN assigned; END IF;
      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.ensure_interface_fleet_ordinal(p_device text, p_interface text)
    RETURNS bigint LANGUAGE plpgsql AS $$
    DECLARE
      device_ordinal bigint;
      live boolean;
      assigned bigint;
    BEGIN
      device_ordinal := platform.ensure_device_fleet_ordinal(p_device);
      live := device_ordinal IS NOT NULL AND EXISTS (
        SELECT 1 FROM platform.discovered_interfaces
        WHERE device_id = p_device AND interface_uid = p_interface
      );
      SELECT ordinal INTO assigned FROM platform.interface_fleet_ordinals
        WHERE device_uid = p_device AND interface_uid = p_interface;
      IF assigned IS NOT NULL THEN
        UPDATE platform.interface_fleet_ordinals SET tombstoned = NOT live
          WHERE device_uid = p_device AND interface_uid = p_interface
            AND tombstoned IS DISTINCT FROM NOT live;
      ELSIF live THEN
        INSERT INTO platform.interface_fleet_ordinals(device_uid, interface_uid)
          VALUES (p_device, p_interface) RETURNING ordinal INTO assigned;
      END IF;
      IF live THEN RETURN assigned; END IF;
      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.clear_restored_identity_purge() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      NEW.identity_purged_at := NULL;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_clear_restored_identity_purge
    BEFORE UPDATE OF deleted_at ON platform.ocsf_devices
    FOR EACH ROW WHEN (OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL)
    EXECUTE FUNCTION platform.clear_restored_identity_purge()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.sync_device_fleet_identity() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE assigned bigint;
    BEGIN
      assigned := platform.ensure_device_fleet_ordinal(NEW.uid);
      -- Only existing interface assignments are touched here; bounded backfill
      -- creates missing ones. Deleted interfaces remain tombstoned on restore.
      UPDATE platform.interface_fleet_ordinals AS o
      SET tombstoned = assigned IS NULL OR NOT EXISTS (
        SELECT 1 FROM platform.discovered_interfaces AS i
        WHERE i.device_id = o.device_uid AND i.interface_uid = o.interface_uid
      )
      WHERE o.device_uid = NEW.uid AND o.tombstoned IS DISTINCT FROM (
        assigned IS NULL OR NOT EXISTS (
          SELECT 1 FROM platform.discovered_interfaces AS i
          WHERE i.device_id = o.device_uid AND i.interface_uid = o.interface_uid
        )
      );
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_device_fleet_identity_insert AFTER INSERT ON platform.ocsf_devices
      FOR EACH ROW EXECUTE FUNCTION platform.sync_device_fleet_identity()
    """)

    execute("""
    CREATE TRIGGER trg_device_fleet_identity_update
      AFTER UPDATE OF deleted_at, deleted_reason, is_active ON platform.ocsf_devices
      FOR EACH ROW WHEN (OLD.deleted_at IS DISTINCT FROM NEW.deleted_at
        OR OLD.deleted_reason IS DISTINCT FROM NEW.deleted_reason
        OR OLD.is_active IS DISTINCT FROM NEW.is_active)
      EXECUTE FUNCTION platform.sync_device_fleet_identity()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.sync_interface_fleet_identity() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      -- Deletion/moves and allocation share the parent lock. Otherwise a backfill
      -- can revive a membership using an existence snapshot taken before deletion.
      IF TG_OP = 'DELETE' THEN
        PERFORM uid FROM platform.ocsf_devices WHERE uid = OLD.device_id FOR NO KEY UPDATE;
      ELSIF TG_OP = 'UPDATE' THEN
        PERFORM uid FROM platform.ocsf_devices WHERE uid IN (OLD.device_id, NEW.device_id)
          ORDER BY uid FOR NO KEY UPDATE;
      END IF;
      IF TG_OP <> 'INSERT' THEN
        IF TG_OP = 'DELETE' OR (OLD.device_id, OLD.interface_uid)
            IS DISTINCT FROM (NEW.device_id, NEW.interface_uid) THEN
          UPDATE platform.interface_fleet_ordinals SET tombstoned = true
            WHERE device_uid = OLD.device_id AND interface_uid = OLD.interface_uid;
        END IF;
      END IF;
      IF TG_OP <> 'DELETE' THEN
        PERFORM platform.ensure_interface_fleet_ordinal(NEW.device_id, NEW.interface_uid);
        RETURN NEW;
      END IF;
      RETURN OLD;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_interface_fleet_identity_insert AFTER INSERT ON platform.discovered_interfaces
      FOR EACH ROW EXECUTE FUNCTION platform.sync_interface_fleet_identity()
    """)

    execute("""
    CREATE TRIGGER trg_interface_fleet_identity_update
      AFTER UPDATE OF device_id, interface_uid ON platform.discovered_interfaces
      FOR EACH ROW WHEN ((OLD.device_id, OLD.interface_uid) IS DISTINCT FROM (NEW.device_id, NEW.interface_uid))
      EXECUTE FUNCTION platform.sync_interface_fleet_identity()
    """)

    execute("""
    CREATE TRIGGER trg_interface_fleet_identity_delete AFTER DELETE ON platform.discovered_interfaces
      FOR EACH ROW EXECUTE FUNCTION platform.sync_interface_fleet_identity()
    """)
    execute("""
    CREATE OR REPLACE FUNCTION platform.trg_ansible_awx_membership_device_deleted()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM platform.ocsf_devices
        WHERE uid = OLD.canonical_device_uid AND identity_purged_at IS NULL
      ) THEN
        NEW.link_disposition := 'quarantined';
        NEW.link_evidence := NEW.link_evidence || jsonb_build_object(
          'canonical_device_deleted', jsonb_build_object(
            'device_uid', OLD.canonical_device_uid,
            'deleted_at', now() AT TIME ZONE 'utc'
          )
        );
        NEW.updated_at := now() AT TIME ZONE 'utc';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

  end

  def down do
    execute("DROP TRIGGER IF EXISTS trg_clear_restored_identity_purge ON platform.ocsf_devices")
    execute("DROP TRIGGER IF EXISTS trg_device_fleet_identity_insert ON platform.ocsf_devices")
    execute("DROP TRIGGER IF EXISTS trg_device_fleet_identity_update ON platform.ocsf_devices")
    execute("DROP TRIGGER IF EXISTS trg_interface_fleet_identity_insert ON platform.discovered_interfaces")
    execute("DROP TRIGGER IF EXISTS trg_interface_fleet_identity_update ON platform.discovered_interfaces")
    execute("DROP TRIGGER IF EXISTS trg_interface_fleet_identity_delete ON platform.discovered_interfaces")
  end
end
