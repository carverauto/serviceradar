defmodule ServiceRadar.Repo.Migrations.AddExposureDeviceLifecycle do
  @moduledoc """
  Exposure lifecycle publication preserves stable fleet ordinals across restores.
  Source triggers cover every writer of the shared dictionary. Restoration work
  is queued transactionally and drained in bounded pages outside the device lock.

  serviceradar:allow-startup-maintenance - DML belongs to later lifecycle and
  assessment transactions; no fleet scan or assessment backfill runs at startup.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("""
    ALTER TABLE platform.device_fleet_ordinals
      ADD COLUMN lifecycle_seq bigint NOT NULL DEFAULT 0,
      ADD COLUMN lifecycle_xid xid8,
      ADD COLUMN lifecycle_at timestamp without time zone,
      ADD COLUMN retired_seq bigint,
      ADD COLUMN retired_xid xid8,
      ADD COLUMN retired_at timestamp without time zone
    """)
    execute("""
    ALTER TABLE platform.endpoint_vulnerability_assessments
      ADD COLUMN last_device_lifecycle_seq bigint
    """)
    execute("""
    CREATE TABLE platform.exposure_device_refreshes (
      device_uid text PRIMARY KEY,
      lifecycle_seq bigint NOT NULL,
      inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    )
    """)
    execute("CREATE INDEX exposure_device_refreshes_oldest_idx ON platform.exposure_device_refreshes (inserted_at, device_uid)")
    execute("""
    CREATE TABLE platform.exposure_delivery_batches (
      bucket integer PRIMARY KEY CHECK (bucket BETWEEN 0 AND 15),
      stream_sequences bigint[] NOT NULL,
      inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    )
    """)
    execute("""
    CREATE FUNCTION platform.exposure_device_lifecycle_sequence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'INSERT' AND NOT NEW.tombstoned THEN RETURN NEW; END IF;
      IF TG_OP = 'UPDATE' AND OLD.tombstoned = NEW.tombstoned THEN RETURN NEW; END IF;
      IF TG_OP = 'UPDATE' AND OLD.tombstoned AND NOT NEW.tombstoned
         AND NEW.retired_seq IS NULL THEN
        -- An ordinal tombstoned before lifecycle publication still needs a fence.
        NEW.retired_seq := nextval('platform.exposure_transition_seq');
        NEW.retired_xid := pg_current_xact_id();
        NEW.retired_at := clock_timestamp() AT TIME ZONE 'utc';
      END IF;
      NEW.lifecycle_seq := nextval('platform.exposure_transition_seq');
      NEW.lifecycle_xid := pg_current_xact_id();
      NEW.lifecycle_at := clock_timestamp() AT TIME ZONE 'utc';
      IF NEW.tombstoned THEN
        NEW.retired_seq := NEW.lifecycle_seq;
        NEW.retired_xid := NEW.lifecycle_xid;
        NEW.retired_at := NEW.lifecycle_at;
      END IF;
      RETURN NEW;
    END;
    $$
    """)
    execute("""
    CREATE FUNCTION platform.exposure_device_lifecycle_publish() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.lifecycle_seq = 0 THEN RETURN NEW; END IF;
      IF TG_OP = 'UPDATE' AND OLD.lifecycle_seq = NEW.lifecycle_seq THEN RETURN NEW; END IF;
      INSERT INTO platform.exposure_transition_outbox
        (device_uid, transition_seq, transition_xid, payload)
      VALUES (NEW.uid, NEW.lifecycle_seq, NEW.lifecycle_xid, jsonb_build_object(
        'schema_version', 1,
        'event_type', CASE WHEN NEW.tombstoned THEN 'device_retired' ELSE 'device_restored' END,
        'state', CASE WHEN NEW.tombstoned THEN 'retired' ELSE 'live' END,
        'device_uid', NEW.uid, 'device_ord', NEW.ordinal,
        'transition_seq', NEW.lifecycle_seq, 'device_lifecycle_seq', NEW.lifecycle_seq,
        'transition_xid', NEW.lifecycle_xid::text::numeric,
        'changed_at', NEW.lifecycle_at, 'retired_seq', COALESCE(NEW.retired_seq, 0),
        'retired_xid', NEW.retired_xid::text::numeric, 'retired_at', NEW.retired_at));
      IF NOT NEW.tombstoned THEN
        INSERT INTO platform.exposure_device_refreshes(device_uid, lifecycle_seq)
          VALUES (NEW.uid, NEW.lifecycle_seq)
          ON CONFLICT (device_uid) DO UPDATE SET lifecycle_seq = EXCLUDED.lifecycle_seq,
            inserted_at = now() AT TIME ZONE 'utc';
      END IF;
      RETURN NEW;
    END;
    $$
    """)
    execute("""
    CREATE TRIGGER trg_exposure_device_lifecycle_sequence
    BEFORE INSERT OR UPDATE OF tombstoned ON platform.device_fleet_ordinals
    FOR EACH ROW EXECUTE FUNCTION platform.exposure_device_lifecycle_sequence()
    """)
    execute("""
    CREATE TRIGGER trg_exposure_device_lifecycle_publish
    AFTER INSERT OR UPDATE OF tombstoned ON platform.device_fleet_ordinals
    FOR EACH ROW EXECUTE FUNCTION platform.exposure_device_lifecycle_publish()
    """)
    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_record_transition(
      p_row platform.endpoint_vulnerability_assessments,
      p_actionable boolean,
      p_seq bigint,
      p_reason text,
      p_changed_fields text[]
    ) RETURNS void
    LANGUAGE plpgsql AS $$
    DECLARE
      v_xid xid8 := pg_current_xact_id();
      v_changed_at timestamp without time zone := now() AT TIME ZONE 'utc';
      v_device_ord bigint;
      v_lifecycle bigint;
      v_retired boolean;
    BEGIN
      SELECT ordinal, lifecycle_seq, tombstoned INTO v_device_ord, v_lifecycle, v_retired
        FROM platform.device_fleet_ordinals WHERE uid = p_row.device_uid FOR SHARE;
      IF COALESCE(v_retired, false) THEN RETURN; END IF;

      INSERT INTO platform.exposure_transition_outbox
        (transition_seq, transition_xid, device_uid, payload)
      VALUES (
        p_seq,
        v_xid,
        p_row.device_uid,
        jsonb_build_object(
          'schema_version', 1,
          'transition_seq', p_seq,
          'transition_xid', v_xid::text::numeric,
          'device_uid', p_row.device_uid,
          'package_identity_key', p_row.package_identity_key,
          'cve_id', p_row.cve_id,
          'installed_version', p_row.installed_version,
          'device_ord', v_device_ord,
          'device_lifecycle_seq', COALESCE(v_lifecycle, 0),
          'cve_ord', platform.exposure_cve_ordinal(p_row.cve_id),
          'pkg_ord', platform.exposure_package_ordinal(p_row.package_identity_key),
          'pkgver_ord', platform.exposure_package_version_ordinal(
            p_row.package_identity_key, p_row.installed_version),
          'state', CASE WHEN p_actionable THEN 'active' ELSE 'resolved' END,
          'source_scope', p_row.source_scope,
          'severity', p_row.severity,
          'cvss_score', p_row.cvss_score,
          'kev', p_row.kev,
          'exploit_available', p_row.exploit_available,
          'fixed_version', p_row.fixed_version,
          'fix_available', COALESCE(btrim(p_row.fixed_version), '') <> '',
          'first_exposed_at', p_row.exposed_at,
          'resolved_at', CASE WHEN p_actionable THEN NULL ELSE v_changed_at END,
          'changed_at', v_changed_at,
          'changed_fields', to_jsonb(p_changed_fields),
          'reason', p_reason,
          'assessment_status', p_row.status,
          'assessment', p_row.assessment,
          'disposition', p_row.disposition,
          'assessment_transition_reason', p_row.transition_reason
        )
      );
    END;
    $$
    """)
    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_retire_assessment_key(
      p_row platform.endpoint_vulnerability_assessments,
      p_reason text
    ) RETURNS void
    LANGUAGE plpgsql AS $$
    DECLARE
      v_seq bigint;
    BEGIN
      PERFORM 1 FROM platform.device_fleet_ordinals WHERE uid = p_row.device_uid FOR SHARE;
      v_seq := nextval('platform.exposure_transition_seq');
      PERFORM platform.exposure_record_transition(p_row, false, v_seq, p_reason, ARRAY['state']);

      INSERT INTO platform.exposure_fact_watermarks
        (device_uid, package_identity_key, cve_id, state, transition_seq, transition_xid, updated_at)
      VALUES
        (p_row.device_uid, p_row.package_identity_key, p_row.cve_id, 'resolved', v_seq,
         pg_current_xact_id(), now() AT TIME ZONE 'utc')
      ON CONFLICT (device_uid, package_identity_key, cve_id) DO UPDATE
        SET state = EXCLUDED.state,
            transition_seq = EXCLUDED.transition_seq,
            transition_xid = EXCLUDED.transition_xid,
            updated_at = EXCLUDED.updated_at
        WHERE platform.exposure_fact_watermarks.transition_seq < EXCLUDED.transition_seq;
    END;
    $$
    """)
    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_assessment_sequence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      is_actionable boolean :=
        platform.exposure_assessment_actionable(NEW.status, NEW.assessment, NEW.disposition);
      was_actionable boolean;
      lifecycle bigint := 0;
      retired boolean := false;
    BEGIN
      -- Share locks permit independent facts but exclude a lifecycle change until
      -- all earlier publications commit. No canonical device row is locked here.
      SELECT lifecycle_seq, tombstoned INTO lifecycle, retired
        FROM platform.device_fleet_ordinals WHERE uid = NEW.device_uid FOR SHARE;
      lifecycle := COALESCE(lifecycle, 0);
      IF COALESCE(retired, false) THEN
        IF TG_OP = 'INSERT' THEN
          NEW.last_transition_seq := NULL;
          NEW.last_device_lifecycle_seq := NULL;
          NEW.exposed_at := NULL;
        ELSE
          NEW.last_transition_seq := OLD.last_transition_seq;
          NEW.last_device_lifecycle_seq := OLD.last_device_lifecycle_seq;
          NEW.exposed_at := OLD.exposed_at;
        END IF;
        RETURN NEW;
      END IF;
      NEW.last_device_lifecycle_seq := lifecycle;
      IF TG_OP = 'INSERT'
         OR (OLD.device_uid, OLD.package_identity_key, OLD.cve_id)
            IS DISTINCT FROM (NEW.device_uid, NEW.package_identity_key, NEW.cve_id) THEN
        IF is_actionable THEN
          NEW.last_transition_seq := nextval('platform.exposure_transition_seq');
          NEW.exposed_at := now() AT TIME ZONE 'utc';
        ELSE
          NEW.last_transition_seq := NULL;
          NEW.exposed_at := NULL;
        END IF;
        RETURN NEW;
      END IF;

      NEW.last_transition_seq := OLD.last_transition_seq;
      NEW.exposed_at := OLD.exposed_at;
      was_actionable :=
        platform.exposure_assessment_actionable(OLD.status, OLD.assessment, OLD.disposition);

      IF (is_actionable AND OLD.last_device_lifecycle_seq IS DISTINCT FROM lifecycle)
         OR is_actionable IS DISTINCT FROM was_actionable
         OR (is_actionable AND
             (OLD.installed_version, OLD.kev, OLD.exploit_available, OLD.cvss_score,
              OLD.severity, OLD.fixed_version)
             IS DISTINCT FROM
             (NEW.installed_version, NEW.kev, NEW.exploit_available, NEW.cvss_score,
              NEW.severity, NEW.fixed_version)) THEN
        NEW.last_transition_seq := nextval('platform.exposure_transition_seq');
        IF is_actionable AND NOT was_actionable THEN
          NEW.exposed_at := now() AT TIME ZONE 'utc';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$
    """)
  end

  def down do
    raise "Exposure lifecycle watermarks cannot be discarded; deploy a compatible forward migration"
  end
end
