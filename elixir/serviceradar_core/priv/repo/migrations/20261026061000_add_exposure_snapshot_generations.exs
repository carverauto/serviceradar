defmodule ServiceRadar.Repo.Migrations.AddExposureSnapshotGenerations do
  @moduledoc """
  Snapshot manifests, bounded lane progress and repair obligations; never fact payloads.
  serviceradar:allow-startup-maintenance - function DML runs only when a later
  snapshot requests a repair. This migration performs no source backfill.
  """
  use Ecto.Migration

  def up do
    create table(:exposure_snapshot_generations, primary_key: false, prefix: "platform") do
      add :id, :bigserial, primary_key: true
      add :status, :text, null: false
      add :control, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:exposure_snapshot_generations, :exposure_snapshot_status,
             prefix: "platform",
             check: "status IN ('publishing', 'published', 'finalizing', 'complete', 'aborted')"
           )

    execute("""
    CREATE UNIQUE INDEX exposure_snapshot_one_active
    ON platform.exposure_snapshot_generations ((true))
    WHERE status NOT IN ('complete', 'aborted')
    """)

    execute("""
    CREATE FUNCTION platform.exposure_prepare_snapshot_publication(p_uid text, p_package text, p_cve text)
    RETURNS jsonb LANGUAGE plpgsql AS $$
    DECLARE body jsonb; package_name text; source_ordinal bigint;
    BEGIN
      body := platform.exposure_repair_publication(p_uid, p_package, p_cve, 0, true);
      IF body IS NULL THEN RETURN NULL; END IF;
      SELECT ordinal INTO source_ordinal FROM platform.device_fleet_ordinals WHERE uid = p_uid;
      IF source_ordinal IS NULL THEN RETURN NULL; END IF;
      IF (body->>'device_ord')::bigint IS DISTINCT FROM source_ordinal THEN
        body := platform.exposure_repair_publication(
          p_uid, p_package, p_cve, (body->>'transition_seq')::bigint, false);
        IF body IS NULL THEN RETURN NULL; END IF;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM platform.device_fleet_ordinals
        WHERE uid = p_uid AND ordinal = (body->>'device_ord')::bigint) THEN
        RAISE EXCEPTION 'Exposure publication ordinal dictionary is missing';
      END IF;
      PERFORM platform.exposure_publish_dimension('cve', (body->>'cve_ord')::bigint,
        jsonb_build_object('cve_ord', body->'cve_ord', 'cve_id', p_cve, 'epss_score', NULL), true);
      SELECT COALESCE(NULLIF(btrim(a.package_name), ''), NULLIF(btrim(a.binary_package), ''))
        INTO package_name FROM platform.endpoint_vulnerability_assessments a
        WHERE a.device_uid = p_uid AND a.package_identity_key = p_package AND a.cve_id = p_cve;
      PERFORM platform.exposure_publish_dimension('package', (body->>'pkgver_ord')::bigint,
        jsonb_build_object('pkgver_ord', body->'pkgver_ord', 'pkg_ord', body->'pkg_ord',
          'package_identity_key', p_package, 'installed_version', body->>'installed_version',
          'package_name', COALESCE(package_name, p_package)), true);
      RETURN body;
    END;
    $$
    """)

    execute("""
    CREATE FUNCTION platform.exposure_lifecycle_publication(p_ordinal bigint)
    RETURNS jsonb LANGUAGE sql STABLE AS $$
      SELECT jsonb_build_object(
        'schema_version', 1, 'device_uid', uid, 'device_ord', ordinal,
        'event_type', CASE WHEN tombstoned THEN 'device_retired' ELSE 'device_restored' END,
        'state', CASE WHEN tombstoned THEN 'retired' ELSE 'live' END,
        'transition_seq', lifecycle_seq, 'device_lifecycle_seq', lifecycle_seq,
        'transition_xid', lifecycle_xid::text::numeric, 'changed_at', lifecycle_at,
        'retired_seq', retired_seq, 'retired_xid', retired_xid::text::numeric, 'retired_at', retired_at)
      FROM platform.device_fleet_ordinals WHERE ordinal = p_ordinal AND lifecycle_seq > 0;
    $$
    """)

    execute("""
    CREATE FUNCTION platform.exposure_repair_dimension(p_kind text, p_ordinal bigint, p_floor bigint)
    RETURNS jsonb LANGUAGE plpgsql AS $$
    DECLARE source platform.exposure_dimension_state; seq bigint; body jsonb;
    BEGIN
      IF current_setting('transaction_isolation') <> 'read committed' OR p_floor IS NULL OR p_floor < 0 THEN
        RAISE EXCEPTION 'Exposure dimension repair requires READ COMMITTED and a nonnegative floor';
      END IF;
      SELECT * INTO source FROM platform.exposure_dimension_state
        WHERE kind = p_kind AND ordinal = p_ordinal FOR UPDATE;
      IF NOT FOUND THEN RETURN NULL; END IF;
      IF source.transition_seq > p_floor THEN
        body := source.payload;
      ELSE
        seq := platform.exposure_next_sequence(p_floor);
        body := source.content || jsonb_build_object(
          'schema_version', 1, 'dimension', p_kind, 'transition_seq', seq,
          'updated_at', clock_timestamp() AT TIME ZONE 'utc');
        UPDATE platform.exposure_dimension_state SET transition_seq = seq, payload = body
          WHERE kind = p_kind AND ordinal = p_ordinal;
      END IF;
      INSERT INTO platform.exposure_dimension_outbox(kind, ordinal, transition_seq, payload)
        VALUES (p_kind, p_ordinal, (body->>'transition_seq')::bigint, body);
      RETURN body;
    END;
    $$
    """)

    execute("""
    CREATE FUNCTION platform.exposure_repair_lifecycle(p_ordinal bigint, p_floor bigint)
    RETURNS jsonb LANGUAGE plpgsql AS $$
    DECLARE source platform.device_fleet_ordinals; seq bigint; body jsonb;
    BEGIN
      IF current_setting('transaction_isolation') <> 'read committed' OR p_floor IS NULL OR p_floor < 0 THEN
        RAISE EXCEPTION 'Exposure lifecycle repair requires READ COMMITTED and a nonnegative floor';
      END IF;
      SELECT * INTO source FROM platform.device_fleet_ordinals WHERE ordinal = p_ordinal FOR UPDATE;
      IF NOT FOUND OR source.lifecycle_seq = 0 THEN RETURN NULL; END IF;
      IF source.lifecycle_seq > p_floor THEN
        body := platform.exposure_lifecycle_publication(p_ordinal);
        PERFORM platform.exposure_enqueue_publication(body);
        RETURN body;
      END IF;
      seq := platform.exposure_next_sequence(p_floor);
      -- The state is unchanged. The existing trigger publishes the new marker
      -- and schedules bounded fact republication for a live lifecycle.
      UPDATE platform.device_fleet_ordinals SET tombstoned = tombstoned,
        lifecycle_seq = seq, lifecycle_xid = pg_current_xact_id(),
        lifecycle_at = clock_timestamp() AT TIME ZONE 'utc',
        retired_seq = CASE WHEN tombstoned THEN seq ELSE retired_seq END,
        retired_xid = CASE WHEN tombstoned THEN pg_current_xact_id() ELSE retired_xid END,
        retired_at = CASE WHEN tombstoned THEN clock_timestamp() AT TIME ZONE 'utc' ELSE retired_at END
        WHERE ordinal = p_ordinal;
      RETURN platform.exposure_lifecycle_publication(p_ordinal);
    END;
    $$
    """)
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM platform.exposure_snapshot_generations
        WHERE status NOT IN ('complete', 'aborted') OR control->'pending' <> '{}'::jsonb) THEN
        RAISE EXCEPTION 'Settle exposure snapshot generations before downgrading';
      END IF;
    END $$
    """)

    execute("DROP FUNCTION platform.exposure_repair_lifecycle(bigint, bigint)")
    execute("DROP FUNCTION platform.exposure_repair_dimension(text, bigint, bigint)")
    execute("DROP FUNCTION platform.exposure_lifecycle_publication(bigint)")
    execute("DROP FUNCTION platform.exposure_prepare_snapshot_publication(text, text, text)")
    drop table(:exposure_snapshot_generations, prefix: "platform")
  end
end
