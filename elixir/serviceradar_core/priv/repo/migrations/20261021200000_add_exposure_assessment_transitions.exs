defmodule ServiceRadar.Repo.Migrations.AddExposureAssessmentTransitions do
  @moduledoc """
  Records exposure transitions of vulnerability assessments in a transactional
  outbox (OpenSpec `add-srql-exposure-intelligence`, *Assessment Transitions Are
  Published On JetStream*).

  A transition is written by triggers on `platform.endpoint_vulnerability_assessments`,
  in the same transaction as the assessment change, whichever writer made it:

    * `last_transition_seq` is drawn from `platform.exposure_transition_seq` while
      the row is locked by the INSERT, UPDATE or DELETE, so per row the sequence
      follows commit order. Only the triggers write it (and `exposed_at`).
    * An assessment produces a transition when it enters or leaves the exact
      actionable state (`active` / `confirmed` / `affected`), or when an
      actionable assessment's installed version, KEV flag, exploit flag, CVSS
      score, severity or fixed version changes. Nothing else does.
    * Deleting a row that was ever published (or is actionable) draws a new
      sequence, publishes `resolved` at it and records the key, state and
      sequence in `platform.exposure_fact_watermarks`. Re-creating the key as
      actionable removes that watermark in the same transaction.
    * Each outbox row carries the producing transaction's `pg_current_xact_id()`
      and the device, CVE, package and package-version ordinals, allocated in
      that transaction. CVE ordinals follow `exposure_cve_ordinal/1`; package
      identities and package versions get sequence-backed dictionary ordinals.

  Rows that were actionable before this migration carry no sequence until their
  next transition; a reader treats a NULL `last_transition_seq` as 0.

  Expand-only: new nullable columns (no rewrite), new tables, sequences,
  functions and triggers. No backfill.

  serviceradar:allow-startup-maintenance - the UPDATE/DELETE statements are inside
  trigger functions and run only with later assessment writes; the migration
  itself performs no DML.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("CREATE SEQUENCE IF NOT EXISTS platform.exposure_transition_seq AS bigint")

    execute("""
    ALTER TABLE platform.endpoint_vulnerability_assessments
      ADD COLUMN IF NOT EXISTS last_transition_seq bigint,
      ADD COLUMN IF NOT EXISTS exposed_at timestamp without time zone
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS platform.exposure_transition_outbox (
      id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      transition_seq bigint NOT NULL,
      transition_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
      device_uid text NOT NULL,
      payload jsonb NOT NULL,
      inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS platform.exposure_fact_watermarks (
      device_uid text NOT NULL,
      package_identity_key text NOT NULL,
      cve_id text NOT NULL,
      state text NOT NULL CHECK (state = 'resolved'),
      transition_seq bigint NOT NULL,
      transition_xid xid8 NOT NULL,
      updated_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      PRIMARY KEY (device_uid, package_identity_key, cve_id)
    )
    """)

    # Dictionary ordinals are never reused: each comes from its own sequence.
    # Non-conforming advisory identifiers start at 10^12, above every
    # deterministic CVE ordinal (at most 9999 * 10^7 + 9999999).
    execute("""
    CREATE SEQUENCE IF NOT EXISTS platform.exposure_advisory_ordinal_seq AS bigint
      MINVALUE 1000000000000 START WITH 1000000000000
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS platform.exposure_advisory_ordinals (
      advisory_id text PRIMARY KEY,
      ordinal bigint NOT NULL UNIQUE DEFAULT nextval('platform.exposure_advisory_ordinal_seq'),
      inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    )
    """)

    execute("CREATE SEQUENCE IF NOT EXISTS platform.exposure_package_ordinal_seq AS bigint")

    execute("""
    CREATE TABLE IF NOT EXISTS platform.exposure_package_ordinals (
      package_identity_key text PRIMARY KEY,
      ordinal bigint NOT NULL UNIQUE DEFAULT nextval('platform.exposure_package_ordinal_seq'),
      inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    )
    """)

    execute(
      "CREATE SEQUENCE IF NOT EXISTS platform.exposure_package_version_ordinal_seq AS bigint"
    )

    execute("""
    CREATE TABLE IF NOT EXISTS platform.exposure_package_version_ordinals (
      package_identity_key text NOT NULL,
      installed_version text NOT NULL,
      ordinal bigint NOT NULL UNIQUE
        DEFAULT nextval('platform.exposure_package_version_ordinal_seq'),
      inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      PRIMARY KEY (package_identity_key, installed_version)
    )
    """)

    # CVE-YYYY-N in canonical form (four zero-padded digits, or five to seven
    # without a leading zero) maps to YYYY * 10^7 + N on every installation.
    # Anything else, including an eight-digit sequence, takes a dictionary
    # ordinal, so two spellings of one number never share an ordinal.
    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_cve_ordinal(p_cve_id text) RETURNS bigint
    LANGUAGE plpgsql AS $$
    DECLARE
      parts text[];
      assigned bigint;
    BEGIN
      IF p_cve_id IS NULL THEN
        RETURN NULL;
      END IF;

      parts := regexp_match(p_cve_id, '^CVE-([0-9]{4})-([0-9]{4}|[1-9][0-9]{4,6})$');
      IF parts IS NOT NULL THEN
        RETURN parts[1]::bigint * 10000000 + parts[2]::bigint;
      END IF;

      SELECT ordinal INTO assigned FROM platform.exposure_advisory_ordinals
        WHERE advisory_id = p_cve_id;
      IF assigned IS NULL THEN
        INSERT INTO platform.exposure_advisory_ordinals (advisory_id) VALUES (p_cve_id)
          ON CONFLICT (advisory_id) DO NOTHING
          RETURNING ordinal INTO assigned;
      END IF;
      IF assigned IS NULL THEN
        SELECT ordinal INTO assigned FROM platform.exposure_advisory_ordinals
          WHERE advisory_id = p_cve_id;
      END IF;
      RETURN assigned;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_package_ordinal(p_key text) RETURNS bigint
    LANGUAGE plpgsql AS $$
    DECLARE
      assigned bigint;
    BEGIN
      SELECT ordinal INTO assigned FROM platform.exposure_package_ordinals
        WHERE package_identity_key = p_key;
      IF assigned IS NULL THEN
        INSERT INTO platform.exposure_package_ordinals (package_identity_key) VALUES (p_key)
          ON CONFLICT (package_identity_key) DO NOTHING
          RETURNING ordinal INTO assigned;
      END IF;
      IF assigned IS NULL THEN
        SELECT ordinal INTO assigned FROM platform.exposure_package_ordinals
          WHERE package_identity_key = p_key;
      END IF;
      RETURN assigned;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_package_version_ordinal(p_key text, p_version text)
    RETURNS bigint
    LANGUAGE plpgsql AS $$
    DECLARE
      v_version text := COALESCE(p_version, '');
      v_assigned bigint;
    BEGIN
      SELECT ordinal INTO v_assigned FROM platform.exposure_package_version_ordinals
        WHERE package_identity_key = p_key AND installed_version = v_version;
      IF v_assigned IS NULL THEN
        INSERT INTO platform.exposure_package_version_ordinals (package_identity_key, installed_version)
          VALUES (p_key, v_version)
          ON CONFLICT (package_identity_key, installed_version) DO NOTHING
          RETURNING ordinal INTO v_assigned;
      END IF;
      IF v_assigned IS NULL THEN
        SELECT ordinal INTO v_assigned FROM platform.exposure_package_version_ordinals
          WHERE package_identity_key = p_key AND installed_version = v_version;
      END IF;
      RETURN v_assigned;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_assessment_actionable(
      p_status text, p_assessment text, p_disposition text
    ) RETURNS boolean
    LANGUAGE sql IMMUTABLE AS $$
      SELECT COALESCE(p_status = 'active' AND p_assessment = 'confirmed'
        AND p_disposition = 'affected', false)
    $$
    """)

    # One outbox row: the complete after-image of the fact, never only the
    # changed fields. Ordinals are allocated here, in the producing transaction.
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
    BEGIN
      SELECT ordinal INTO v_device_ord FROM platform.device_fleet_ordinals
        WHERE uid = p_row.device_uid;

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

    # A key that leaves the table (deleted, or moved by a key change) resolves
    # at a NEW sequence, and its watermark keeps that sequence and state.
    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_retire_assessment_key(
      p_row platform.endpoint_vulnerability_assessments,
      p_reason text
    ) RETURNS void
    LANGUAGE plpgsql AS $$
    DECLARE
      v_seq bigint := nextval('platform.exposure_transition_seq');
    BEGIN
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

    # BEFORE: decides whether this write is a transition and, if so, draws its
    # sequence while the row is locked. The two columns are trigger-owned: a
    # value a writer supplies is replaced.
    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_assessment_sequence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      is_actionable boolean :=
        platform.exposure_assessment_actionable(NEW.status, NEW.assessment, NEW.disposition);
      was_actionable boolean;
    BEGIN
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

      IF is_actionable IS DISTINCT FROM was_actionable
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

    # AFTER: writes the outbox row for a transition the BEFORE trigger
    # sequenced. Fires only for rows actually inserted, updated or deleted (an
    # INSERT ... ON CONFLICT row that conflicts and is not updated never gets
    # here).
    execute("""
    CREATE OR REPLACE FUNCTION platform.exposure_assessment_publish() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      is_actionable boolean;
      was_actionable boolean;
      changed text[] := ARRAY[]::text[];
    BEGIN
      IF TG_OP = 'DELETE' THEN
        PERFORM platform.exposure_retire_assessment_key(OLD, 'assessment_deleted');
        RETURN OLD;
      END IF;

      is_actionable :=
        platform.exposure_assessment_actionable(NEW.status, NEW.assessment, NEW.disposition);

      IF TG_OP = 'UPDATE'
         AND (OLD.device_uid, OLD.package_identity_key, OLD.cve_id)
             IS NOT DISTINCT FROM (NEW.device_uid, NEW.package_identity_key, NEW.cve_id) THEN
        was_actionable :=
          platform.exposure_assessment_actionable(OLD.status, OLD.assessment, OLD.disposition);

        IF is_actionable IS DISTINCT FROM was_actionable THEN
          changed := changed || 'state'::text;
        END IF;
        IF OLD.installed_version IS DISTINCT FROM NEW.installed_version THEN
          changed := changed || 'installed_version'::text;
        END IF;
        IF OLD.severity IS DISTINCT FROM NEW.severity THEN
          changed := changed || 'severity'::text;
        END IF;
        IF OLD.cvss_score IS DISTINCT FROM NEW.cvss_score THEN
          changed := changed || 'cvss_score'::text;
        END IF;
        IF OLD.kev IS DISTINCT FROM NEW.kev THEN
          changed := changed || 'kev'::text;
        END IF;
        IF OLD.exploit_available IS DISTINCT FROM NEW.exploit_available THEN
          changed := changed || 'exploit_available'::text;
        END IF;
        IF OLD.fixed_version IS DISTINCT FROM NEW.fixed_version THEN
          changed := changed || 'fixed_version'::text;
        END IF;

        PERFORM platform.exposure_record_transition(
          NEW,
          is_actionable,
          NEW.last_transition_seq,
          CASE
            WHEN is_actionable AND NOT was_actionable THEN 'entered_actionable'
            WHEN was_actionable AND NOT is_actionable THEN 'left_actionable'
            ELSE 'actionable_attributes_changed'
          END,
          changed
        );
        RETURN NEW;
      END IF;

      -- An UPDATE that changed the key retires the old key first.
      IF TG_OP = 'UPDATE'
         AND (OLD.last_transition_seq IS NOT NULL OR
              platform.exposure_assessment_actionable(OLD.status, OLD.assessment, OLD.disposition)) THEN
        PERFORM platform.exposure_retire_assessment_key(OLD, 'assessment_key_changed');
      END IF;

      IF NEW.last_transition_seq IS NOT NULL THEN
        DELETE FROM platform.exposure_fact_watermarks
          WHERE device_uid = NEW.device_uid
            AND package_identity_key = NEW.package_identity_key
            AND cve_id = NEW.cve_id;

        PERFORM platform.exposure_record_transition(
          NEW,
          is_actionable,
          NEW.last_transition_seq,
          'entered_actionable',
          ARRAY['state', 'installed_version', 'severity', 'cvss_score', 'kev',
                'exploit_available', 'fixed_version']
        );
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    DROP TRIGGER IF EXISTS trg_exposure_assessment_sequence
      ON platform.endpoint_vulnerability_assessments
    """)

    execute("""
    CREATE TRIGGER trg_exposure_assessment_sequence
      BEFORE INSERT OR UPDATE ON platform.endpoint_vulnerability_assessments
      FOR EACH ROW EXECUTE FUNCTION platform.exposure_assessment_sequence()
    """)

    execute("""
    DROP TRIGGER IF EXISTS trg_exposure_assessment_publish_insert
      ON platform.endpoint_vulnerability_assessments
    """)

    execute("""
    CREATE TRIGGER trg_exposure_assessment_publish_insert
      AFTER INSERT ON platform.endpoint_vulnerability_assessments
      FOR EACH ROW WHEN (NEW.last_transition_seq IS NOT NULL)
      EXECUTE FUNCTION platform.exposure_assessment_publish()
    """)

    execute("""
    DROP TRIGGER IF EXISTS trg_exposure_assessment_publish_update
      ON platform.endpoint_vulnerability_assessments
    """)

    execute("""
    CREATE TRIGGER trg_exposure_assessment_publish_update
      AFTER UPDATE ON platform.endpoint_vulnerability_assessments
      FOR EACH ROW WHEN (
        OLD.last_transition_seq IS DISTINCT FROM NEW.last_transition_seq
        OR (OLD.device_uid, OLD.package_identity_key, OLD.cve_id)
           IS DISTINCT FROM (NEW.device_uid, NEW.package_identity_key, NEW.cve_id)
      )
      EXECUTE FUNCTION platform.exposure_assessment_publish()
    """)

    execute("""
    DROP TRIGGER IF EXISTS trg_exposure_assessment_publish_delete
      ON platform.endpoint_vulnerability_assessments
    """)

    execute("""
    CREATE TRIGGER trg_exposure_assessment_publish_delete
      AFTER DELETE ON platform.endpoint_vulnerability_assessments
      FOR EACH ROW WHEN (
        OLD.last_transition_seq IS NOT NULL
        OR platform.exposure_assessment_actionable(OLD.status, OLD.assessment, OLD.disposition)
      )
      EXECUTE FUNCTION platform.exposure_assessment_publish()
    """)
  end

  def down do
    execute("""
    DROP TRIGGER IF EXISTS trg_exposure_assessment_publish_delete
      ON platform.endpoint_vulnerability_assessments
    """)

    execute("""
    DROP TRIGGER IF EXISTS trg_exposure_assessment_publish_update
      ON platform.endpoint_vulnerability_assessments
    """)

    execute("""
    DROP TRIGGER IF EXISTS trg_exposure_assessment_publish_insert
      ON platform.endpoint_vulnerability_assessments
    """)

    execute("""
    DROP TRIGGER IF EXISTS trg_exposure_assessment_sequence
      ON platform.endpoint_vulnerability_assessments
    """)

    execute("DROP FUNCTION IF EXISTS platform.exposure_assessment_publish()")
    execute("DROP FUNCTION IF EXISTS platform.exposure_assessment_sequence()")

    execute(
      "DROP FUNCTION IF EXISTS platform.exposure_retire_assessment_key(platform.endpoint_vulnerability_assessments, text)"
    )

    execute(
      "DROP FUNCTION IF EXISTS platform.exposure_record_transition(platform.endpoint_vulnerability_assessments, boolean, bigint, text, text[])"
    )

    execute("DROP FUNCTION IF EXISTS platform.exposure_assessment_actionable(text, text, text)")

    # Sequences, dictionaries, watermarks, the outbox and the trigger-owned
    # columns are kept: ordinals and sequences must never be reused.
  end
end
