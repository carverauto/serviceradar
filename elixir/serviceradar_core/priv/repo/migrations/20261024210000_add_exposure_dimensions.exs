defmodule ServiceRadar.Repo.Migrations.AddExposureDimensions do
  @moduledoc """
  Durable dictionary publication state and an acknowledged outbox (exposure
  Decision 22). No assessment backfill runs at startup.

  serviceradar:allow-startup-maintenance - DML below belongs to functions and
  triggers invoked by later source writes, not migration-time maintenance.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    CREATE TABLE platform.exposure_dimension_state (
      kind text NOT NULL CHECK (kind IN ('cve', 'package')),
      ordinal bigint NOT NULL CHECK (ordinal > 0),
      content jsonb NOT NULL,
      payload jsonb NOT NULL,
      transition_seq bigint NOT NULL,
      PRIMARY KEY (kind, ordinal)
    )
    """)

    execute("""
    CREATE TABLE platform.exposure_dimension_outbox (
      id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      kind text NOT NULL CHECK (kind IN ('cve', 'package')),
      ordinal bigint NOT NULL,
      transition_seq bigint NOT NULL,
      payload jsonb NOT NULL,
      inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    )
    """)

    execute("""
    CREATE FUNCTION platform.exposure_publish_dimension(
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

      seq := nextval('platform.exposure_transition_seq');
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
    CREATE FUNCTION platform.exposure_register_assessment_dimensions() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      cve bigint;
      pkg bigint;
      pkgver bigint;
    BEGIN
      -- Candidates which have never produced a fact do not grow exposure dictionaries.
      IF NEW.last_transition_seq IS NULL AND NOT platform.exposure_assessment_actionable(
        NEW.status, NEW.assessment, NEW.disposition
      ) THEN
        RETURN NEW;
      END IF;

      cve := platform.exposure_cve_ordinal(NEW.cve_id);
      pkg := platform.exposure_package_ordinal(NEW.package_identity_key);
      pkgver := platform.exposure_package_version_ordinal(
        NEW.package_identity_key, NEW.installed_version);
      PERFORM platform.exposure_publish_dimension('cve', cve, jsonb_build_object(
        'cve_ord', cve, 'cve_id', NEW.cve_id, 'epss_score', NULL), true);
      PERFORM platform.exposure_publish_dimension('package', pkgver, jsonb_build_object(
        'pkgver_ord', pkgver, 'pkg_ord', pkg,
        'package_identity_key', NEW.package_identity_key,
        'installed_version', COALESCE(NEW.installed_version, ''),
        'package_name', COALESCE(NULLIF(btrim(NEW.package_name), ''),
          NULLIF(btrim(NEW.binary_package), ''), NEW.package_identity_key)));
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_exposure_dimensions_insert
      AFTER INSERT ON platform.endpoint_vulnerability_assessments
      FOR EACH ROW EXECUTE FUNCTION platform.exposure_register_assessment_dimensions()
    """)

    execute("""
    CREATE TRIGGER trg_exposure_dimensions_update
      AFTER UPDATE ON platform.endpoint_vulnerability_assessments
      FOR EACH ROW WHEN (
        OLD.last_transition_seq IS DISTINCT FROM NEW.last_transition_seq
        OR OLD.package_name IS DISTINCT FROM NEW.package_name
        OR OLD.binary_package IS DISTINCT FROM NEW.binary_package
      ) EXECUTE FUNCTION platform.exposure_register_assessment_dimensions()
    """)
  end

  def down do
    execute("DROP TRIGGER trg_exposure_dimensions_update ON platform.endpoint_vulnerability_assessments")
    execute("DROP TRIGGER trg_exposure_dimensions_insert ON platform.endpoint_vulnerability_assessments")
    execute("DROP FUNCTION platform.exposure_register_assessment_dimensions()")
    execute("DROP FUNCTION platform.exposure_publish_dimension(text, bigint, jsonb, boolean)")
    execute("DROP TABLE platform.exposure_dimension_outbox")
    execute("DROP TABLE platform.exposure_dimension_state")
  end
end
