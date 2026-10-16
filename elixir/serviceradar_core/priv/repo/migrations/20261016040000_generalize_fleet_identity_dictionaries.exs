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
    CREATE OR REPLACE FUNCTION platform.protect_fleet_identity() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE check_violation USING MESSAGE = 'Persistent fleet identities cannot be deleted';
    END;
    $$
    """)

    execute("DROP TRIGGER IF EXISTS trg_protect_fleet_identity_delete ON platform.device_fleet_ordinals")
    execute("""
    CREATE TRIGGER trg_protect_fleet_identity_delete BEFORE DELETE ON platform.device_fleet_ordinals
    FOR EACH ROW EXECUTE FUNCTION platform.protect_fleet_identity()
    """)
    execute("DROP TRIGGER IF EXISTS trg_protect_fleet_identity_truncate ON platform.device_fleet_ordinals")
    execute("""
    CREATE TRIGGER trg_protect_fleet_identity_truncate BEFORE TRUNCATE ON platform.device_fleet_ordinals
    FOR EACH STATEMENT EXECUTE FUNCTION platform.protect_fleet_identity()
    """)

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
    BEGIN
      PERFORM platform.ensure_device_fleet_ordinal(NEW.uid);
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
  end
end
