defmodule ServiceRadar.Repo.Migrations.RetainExposurePublications do
  @moduledoc """
  Source publication records for exact replay after outbox acknowledgement.
  Nullable additions only; bounded preparation runs outside startup migrations.

  serviceradar:allow-startup-maintenance - all DML belongs to later source
  transactions and repair calls; this migration does not backfill assessments.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("""
    ALTER TABLE platform.endpoint_vulnerability_assessments
      ADD COLUMN last_exposure_publication jsonb
    """)

    execute("""
    ALTER TABLE platform.exposure_fact_watermarks ADD COLUMN payload jsonb
    """)

    execute("""
    CREATE FUNCTION platform.exposure_lock_fact(p_uid text, p_package text, p_cve text)
    RETURNS void LANGUAGE sql VOLATILE AS $$
      SELECT pg_advisory_xact_lock(hashtextextended(
        jsonb_build_array(p_uid, p_package, p_cve)::text, 74524));
    $$
    """)

    execute("""
    CREATE FUNCTION platform.exposure_next_sequence(p_floor bigint DEFAULT 0)
    RETURNS bigint LANGUAGE plpgsql AS $$
    DECLARE assigned bigint;
    BEGIN
      IF p_floor < 0 OR p_floor = 9223372036854775807 THEN
        RAISE EXCEPTION 'invalid exposure sequence floor';
      END IF;
      -- A short session lock protects sequence advancement, not the surrounding
      -- transaction. All exposure allocators use it; no unbounded nextval loop.
      BEGIN
        PERFORM pg_advisory_lock(74524, 0);
        assigned := nextval('platform.exposure_transition_seq');
        IF assigned <= p_floor THEN
          assigned := setval('platform.exposure_transition_seq', p_floor + 1, true);
        END IF;
      EXCEPTION WHEN query_canceled OR assert_failure OR OTHERS THEN
        PERFORM pg_advisory_unlock(74524, 0);
        RAISE;
      END;
      PERFORM pg_advisory_unlock(74524, 0);
      RETURN assigned;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_publish_dimension(
      p_kind text, p_ordinal bigint, p_content jsonb, p_insert_only boolean DEFAULT false
    ) RETURNS bigint LANGUAGE plpgsql AS $$
    DECLARE
      existing platform.exposure_dimension_state;
      seq bigint;
      body jsonb;
    BEGIN
      SELECT * INTO existing FROM platform.exposure_dimension_state
        WHERE kind = p_kind AND ordinal = p_ordinal;
      -- Registering an existing CVE never overwrites its enrichment or takes
      -- its write lock on every device update. Mutable content compares below
      -- only after locking, so it cannot skip a concurrent content change.
      IF FOUND AND p_insert_only THEN
        RETURN existing.transition_seq;
      END IF;

      -- The unique key also serializes creation while no row exists. Both the
      -- placeholder and its replacement are invisible until this transaction commits.
      INSERT INTO platform.exposure_dimension_state
        (kind, ordinal, content, payload, transition_seq)
        VALUES (p_kind, p_ordinal, '{}'::jsonb, '{}'::jsonb, 0)
        ON CONFLICT (kind, ordinal) DO NOTHING;
      SELECT * INTO existing FROM platform.exposure_dimension_state
        WHERE kind = p_kind AND ordinal = p_ordinal FOR UPDATE;

      IF existing.transition_seq > 0 AND
         (p_insert_only OR existing.content = p_content) THEN
        RETURN existing.transition_seq;
      END IF;

      seq := platform.exposure_next_sequence();
      body := p_content || jsonb_build_object(
        'schema_version', 1, 'dimension', p_kind, 'transition_seq', seq,
        'updated_at', clock_timestamp() AT TIME ZONE 'utc');
      UPDATE platform.exposure_dimension_state
        SET content = p_content, payload = body, transition_seq = seq
        WHERE kind = p_kind AND ordinal = p_ordinal;
      INSERT INTO platform.exposure_dimension_outbox (kind, ordinal, transition_seq, payload)
        VALUES (p_kind, p_ordinal, seq, body);
      RETURN seq;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_device_lifecycle_sequence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'INSERT' AND NOT NEW.tombstoned THEN RETURN NEW; END IF;
      IF TG_OP = 'UPDATE' AND OLD.tombstoned = NEW.tombstoned
         AND NOT (NEW.tombstoned AND NEW.lifecycle_seq = 0) THEN RETURN NEW; END IF;
      IF TG_OP = 'UPDATE' AND OLD.tombstoned AND NOT NEW.tombstoned
         AND NEW.retired_seq IS NULL THEN
        -- An ordinal tombstoned before lifecycle publication still needs a fence.
        NEW.retired_seq := platform.exposure_next_sequence();
        NEW.retired_xid := pg_current_xact_id();
        NEW.retired_at := clock_timestamp() AT TIME ZONE 'utc';
      END IF;
      NEW.lifecycle_seq := platform.exposure_next_sequence();
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
    CREATE OR REPLACE FUNCTION platform.exposure_transition_payload(
      p_row platform.endpoint_vulnerability_assessments,
      p_actionable boolean,
      p_seq bigint,
      p_reason text,
      p_changed_fields text[]
    ) RETURNS jsonb
    LANGUAGE plpgsql AS $$
    DECLARE
      v_xid xid8 := pg_current_xact_id();
      v_changed_at timestamp without time zone := now() AT TIME ZONE 'utc';
      v_device_ord bigint;
      v_lifecycle bigint;
    BEGIN
      SELECT ordinal, lifecycle_seq INTO v_device_ord, v_lifecycle
        FROM platform.device_fleet_ordinals WHERE uid = p_row.device_uid FOR SHARE;
      RETURN jsonb_build_object(
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
        );
    END;
    $$
    """)

    execute("""
    CREATE FUNCTION platform.exposure_enqueue_publication(p_body jsonb)
    RETURNS void LANGUAGE sql AS $$
      INSERT INTO platform.exposure_transition_outbox
        (device_uid, transition_seq, transition_xid, payload)
      VALUES (p_body->>'device_uid', (p_body->>'transition_seq')::bigint,
        (p_body->>'transition_xid')::xid8, p_body);
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_retire_assessment_key(
      p_row platform.endpoint_vulnerability_assessments, p_reason text
    ) RETURNS void LANGUAGE plpgsql AS $$
    DECLARE seq bigint; body jsonb; retired boolean; floor bigint;
    BEGIN
      PERFORM platform.exposure_lock_fact(p_row.device_uid, p_row.package_identity_key, p_row.cve_id);
      SELECT tombstoned INTO retired FROM platform.device_fleet_ordinals
        WHERE uid = p_row.device_uid FOR SHARE;
      SELECT transition_seq INTO floor FROM platform.exposure_fact_watermarks
        WHERE device_uid = p_row.device_uid AND package_identity_key = p_row.package_identity_key
          AND cve_id = p_row.cve_id;
      seq := platform.exposure_next_sequence(GREATEST(COALESCE(floor, 0),
        COALESCE(p_row.last_transition_seq, 0)));
      body := platform.exposure_transition_payload(p_row, false, seq, p_reason, ARRAY['state']);
      INSERT INTO platform.exposure_fact_watermarks
        (device_uid, package_identity_key, cve_id, state, transition_seq, transition_xid, updated_at, payload)
      VALUES (p_row.device_uid, p_row.package_identity_key, p_row.cve_id, 'resolved', seq,
        (body->>'transition_xid')::xid8, (body->>'changed_at')::timestamp, body)
      ON CONFLICT (device_uid, package_identity_key, cve_id) DO UPDATE
        SET transition_seq = EXCLUDED.transition_seq, transition_xid = EXCLUDED.transition_xid,
          updated_at = EXCLUDED.updated_at, payload = EXCLUDED.payload;
      IF NOT COALESCE(retired, false) THEN
        PERFORM platform.exposure_enqueue_publication(body);
      END IF;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_assessment_sequence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      actionable boolean := platform.exposure_assessment_actionable(NEW.status, NEW.assessment, NEW.disposition);
      was_actionable boolean := false;
      fresh_key boolean := TG_OP = 'INSERT';
      refresh boolean := TG_OP = 'UPDATE' AND COALESCE(NEW.last_exposure_publication = '{}'::jsonb, false);
      lifecycle bigint; retired boolean; floor bigint;
      changed text[] := ARRAY[]::text[];
      field text; reason text;
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        fresh_key := (OLD.device_uid, OLD.package_identity_key, OLD.cve_id)
          IS DISTINCT FROM (NEW.device_uid, NEW.package_identity_key, NEW.cve_id);
        -- Stable order when a single write changes keys. Advisory collisions
        -- merely serialize additional keys; every source lookup uses the full key.
        FOR field IN SELECT DISTINCT value FROM unnest(ARRAY[
          jsonb_build_array(OLD.device_uid, OLD.package_identity_key, OLD.cve_id)::text,
          jsonb_build_array(NEW.device_uid, NEW.package_identity_key, NEW.cve_id)::text
        ]) value ORDER BY value LOOP
          PERFORM pg_advisory_xact_lock(hashtextextended(field, 74524));
        END LOOP;
      ELSE
        PERFORM platform.exposure_lock_fact(NEW.device_uid, NEW.package_identity_key, NEW.cve_id);
      END IF;
      SELECT lifecycle_seq, tombstoned INTO lifecycle, retired
        FROM platform.device_fleet_ordinals WHERE uid = NEW.device_uid FOR SHARE;
      lifecycle := COALESCE(lifecycle, 0);
      IF fresh_key THEN
        NEW.last_transition_seq := NULL;
        NEW.last_exposure_publication := NULL;
        NEW.last_device_lifecycle_seq := NULL;
        NEW.exposed_at := NULL;
      ELSE
        NEW.last_transition_seq := OLD.last_transition_seq;
        NEW.last_exposure_publication := OLD.last_exposure_publication;
        NEW.last_device_lifecycle_seq := OLD.last_device_lifecycle_seq;
        NEW.exposed_at := OLD.exposed_at;
        was_actionable := platform.exposure_assessment_actionable(OLD.status, OLD.assessment, OLD.disposition);
      END IF;
      IF COALESCE(retired, false) THEN RETURN NEW; END IF;
      IF fresh_key THEN
        IF NOT actionable AND NOT refresh THEN RETURN NEW; END IF;
        changed := ARRAY['state', 'installed_version', 'severity', 'cvss_score', 'kev',
          'exploit_available', 'fixed_version'];
        reason := 'entered_actionable';
      ELSE
        IF actionable IS DISTINCT FROM was_actionable THEN changed := changed || 'state'::text; END IF;
        FOREACH field IN ARRAY ARRAY['installed_version', 'severity', 'cvss_score', 'kev',
          'exploit_available', 'fixed_version', 'source_scope'] LOOP
          IF to_jsonb(OLD)->field IS DISTINCT FROM to_jsonb(NEW)->field THEN
            changed := changed || field;
          END IF;
        END LOOP;
        IF NOT refresh AND actionable IS NOT DISTINCT FROM was_actionable
          AND NOT (actionable AND (cardinality(changed) > 0
            OR OLD.last_device_lifecycle_seq IS DISTINCT FROM lifecycle)) THEN
          RETURN NEW;
        END IF;
        reason := CASE WHEN refresh THEN 'snapshot_repair'
          WHEN actionable AND NOT was_actionable THEN 'entered_actionable'
          WHEN was_actionable AND NOT actionable THEN 'left_actionable'
          ELSE 'actionable_attributes_changed' END;
      END IF;
      SELECT transition_seq INTO floor FROM platform.exposure_fact_watermarks
        WHERE device_uid = NEW.device_uid AND package_identity_key = NEW.package_identity_key
          AND cve_id = NEW.cve_id;
      NEW.last_transition_seq := platform.exposure_next_sequence(GREATEST(COALESCE(floor, 0),
        COALESCE(NEW.last_transition_seq, 0), lifecycle));
      NEW.last_device_lifecycle_seq := lifecycle;
      IF actionable AND (fresh_key OR NOT was_actionable OR NEW.exposed_at IS NULL) THEN
        NEW.exposed_at := now() AT TIME ZONE 'utc';
      END IF;
      NEW.last_exposure_publication := platform.exposure_transition_payload(
        NEW, actionable, NEW.last_transition_seq, reason, changed);
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_assessment_publish() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        PERFORM platform.exposure_retire_assessment_key(OLD, 'assessment_deleted');
        RETURN OLD;
      END IF;
      IF TG_OP = 'UPDATE' AND (OLD.device_uid, OLD.package_identity_key, OLD.cve_id)
        IS DISTINCT FROM (NEW.device_uid, NEW.package_identity_key, NEW.cve_id)
        AND (OLD.last_transition_seq IS NOT NULL OR
          platform.exposure_assessment_actionable(OLD.status, OLD.assessment, OLD.disposition)) THEN
        PERFORM platform.exposure_retire_assessment_key(OLD, 'assessment_key_changed');
      END IF;
      IF NEW.last_exposure_publication IS NOT NULL AND (TG_OP = 'INSERT'
        OR NEW.last_transition_seq IS DISTINCT FROM OLD.last_transition_seq) THEN
        DELETE FROM platform.exposure_fact_watermarks WHERE device_uid = NEW.device_uid
          AND package_identity_key = NEW.package_identity_key AND cve_id = NEW.cve_id;
        PERFORM platform.exposure_enqueue_publication(NEW.last_exposure_publication);
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE FUNCTION platform.exposure_assessment_delete_lock() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM platform.exposure_lock_fact(OLD.device_uid, OLD.package_identity_key, OLD.cve_id);
      RETURN OLD;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_exposure_assessment_delete_lock
      BEFORE DELETE ON platform.endpoint_vulnerability_assessments
      FOR EACH ROW EXECUTE FUNCTION platform.exposure_assessment_delete_lock()
    """)

    execute("""
    CREATE FUNCTION platform.exposure_repair_publication(
      p_uid text, p_package text, p_cve text, p_observed_seq bigint DEFAULT 0,
      p_missing_only boolean DEFAULT false
    ) RETURNS jsonb LANGUAGE plpgsql AS $$
    DECLARE source platform.endpoint_vulnerability_assessments;
      watermark platform.exposure_fact_watermarks; retired boolean;
    BEGIN
      IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'exposure repair requires a fresh READ COMMITTED transaction';
      END IF;
      IF p_uid IS NULL OR p_package IS NULL OR p_cve IS NULL OR p_observed_seq IS NULL OR p_observed_seq < 0 THEN
        RAISE EXCEPTION 'invalid exposure repair key or sequence';
      END IF;
      PERFORM platform.exposure_lock_fact(p_uid, p_package, p_cve);
      -- Writers may already own a row lock before their trigger takes the key
      -- lock. Never wait for that row while holding the key: retry the transaction.
      SELECT * INTO source FROM platform.endpoint_vulnerability_assessments
        WHERE device_uid = p_uid AND package_identity_key = p_package AND cve_id = p_cve
        FOR UPDATE NOWAIT;
      IF FOUND THEN
        IF p_missing_only AND source.last_exposure_publication IS NOT NULL THEN
          RETURN source.last_exposure_publication;
        END IF;
        SELECT tombstoned INTO retired FROM platform.device_fleet_ordinals
          WHERE uid = p_uid FOR SHARE;
        IF COALESCE(retired, false) THEN RETURN NULL; END IF;
        PERFORM platform.exposure_next_sequence(p_observed_seq);
        -- An empty publication requests regeneration; the BEFORE trigger always
        -- replaces it with a complete record, including for an unsequenced row.
        UPDATE platform.endpoint_vulnerability_assessments SET last_exposure_publication = '{}'::jsonb
          WHERE id = source.id RETURNING last_exposure_publication INTO source.last_exposure_publication;
        RETURN source.last_exposure_publication;
      END IF;
      SELECT * INTO watermark FROM platform.exposure_fact_watermarks
        WHERE device_uid = p_uid AND package_identity_key = p_package AND cve_id = p_cve;
      IF p_missing_only AND watermark.payload IS NOT NULL THEN RETURN watermark.payload; END IF;
      source.device_uid := p_uid;
      source.package_identity_key := p_package;
      source.cve_id := p_cve;
      source.installed_version := COALESCE(watermark.payload->>'installed_version', '');
      source.last_transition_seq := GREATEST(p_observed_seq, COALESCE(watermark.transition_seq, 0));
      PERFORM platform.exposure_retire_assessment_key(source, 'snapshot_repair');
      SELECT payload INTO watermark.payload FROM platform.exposure_fact_watermarks
        WHERE device_uid = p_uid AND package_identity_key = p_package AND cve_id = p_cve;
      RETURN watermark.payload;
    END;
    $$
    """)

    execute("""
    DROP FUNCTION platform.exposure_record_transition(
      platform.endpoint_vulnerability_assessments, boolean, bigint, text, text[])
    """)

  end

  def down do
    raise "Exposure publication records require a compatible forward migration"
  end
end
