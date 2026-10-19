defmodule ServiceRadar.Repo.Migrations.AddMergedAvailabilityCapture do
  @moduledoc """
  Stage a (capture, mode `legacy`) of `add-merged-device-availability`.

  Every statement here is additive and metadata-only on existing tables. Nothing reads
  the new objects for a decision yet, and every existing writer keeps writing
  `ocsf_devices.is_available` exactly as before:

  * `availability_settings` holds the single `mode` row, created as `legacy`.
  * `device_agent_availability.consecutive_down` (default 0) is the per-agent hysteresis
    counter. A BEFORE trigger maintains it for every ledger writer and touches no other
    column, so `is_available`, `checked_at` and `updated_at` keep their semantics.
  * `device_availability_evidence`, `device_vantage_expectations`,
    `device_availability_shadow` and `device_availability_legacy` are new tables.
  * `availability_invalidations` is the append-only invalidation log. Its producers are
    AFTER triggers that append only on a real change, and only outside `legacy` mode:
    nothing consumes the log before stage b, so appending in `legacy` would grow it with
    no reader.
  * `ocsf_devices.availability_*` columns: the state defaults to `unknown` (a constant
    default, so no rewrite). The mirror trigger keeps `availability_state` equal to the
    projection of `is_available` in `legacy` and `shadow`. Existing rows are projected
    after startup by `ServiceRadar.Inventory.Availability.CaptureBackfillWorker`, which
    this migration enqueues once.
  * `device_availability_legacy` is maintained from `is_available` changes by an AFTER
    trigger in `legacy` and `shadow`. It is seeded for every device only at the drained
    cutover boundary (stage c).
  * `integration_sources.northbound_availability_semantics`, `legacy` for every source.

  Locking: the `ocsf_devices` and ledger triggers write only rows keyed by the device whose
  row the statement already holds, so they add no lock-order edge between devices. They
  never touch the shared rollup counters, whose lock order #5786 fixed.

  serviceradar:allow-startup-maintenance - the UPDATE and DELETE statements in `up` are
  trigger bodies that run later, on writes to the rows they key; none runs during the
  migration. Existing rows are backfilled by the enqueued worker, not here. The one
  DELETE that does run, in `down`, removes only this migration's own pending backfill job.
  """

  use Ecto.Migration

  @prefix "platform"
  @backfill_worker "ServiceRadar.Inventory.Availability.CaptureBackfillWorker"
  @now_utc "(now() AT TIME ZONE 'utc')"
  @classes "('operator_policy', 'self_report', 'managing_controller', 'active_probe', " <>
             "'passive_observation', 'inventory_declared')"
  @states "('available', 'unavailable', 'unknown')"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create_settings()
    create_ledger_counter()
    create_tables()
    alter_devices()
    create_device_triggers()
    create_ledger_triggers()
    create_expectation_triggers()
    alter_integration_sources()

    execute("""
    INSERT INTO #{@prefix}.oban_jobs (state, queue, worker, args, max_attempts)
    VALUES ('available', 'maintenance', '#{@backfill_worker}',
            '{"trigger": "migration"}'::jsonb, 20)
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    DELETE FROM #{@prefix}.oban_jobs
    WHERE worker = '#{@backfill_worker}' AND state IN ('available', 'scheduled', 'retryable')
    """)

    execute(
      "DROP TRIGGER IF EXISTS trg_composite_checks_clear_vantage_expectations ON #{@prefix}.composite_checks"
    )

    execute("DROP FUNCTION IF EXISTS #{@prefix}.trg_composite_checks_clear_vantage_expectations()")

    for trigger <- [
          "trg_ocsf_devices_availability_mirror",
          "trg_ocsf_devices_availability_legacy_insert",
          "trg_ocsf_devices_availability_legacy_update",
          "trg_ocsf_devices_availability_pin_invalidate"
        ] do
      execute("DROP TRIGGER IF EXISTS #{trigger} ON #{@prefix}.ocsf_devices")
    end

    for trigger <- [
          "trg_device_agent_availability_consecutive_down",
          "trg_device_agent_availability_invalidate"
        ] do
      execute("DROP TRIGGER IF EXISTS #{trigger} ON #{@prefix}.device_agent_availability")
    end

    # Dropping the expectations table drops its triggers before their function goes.
    for table <- [
          "device_vantage_expectations",
          "device_availability_evidence",
          "device_availability_shadow",
          "device_availability_legacy",
          "availability_invalidations",
          "availability_settings"
        ] do
      execute("DROP TABLE IF EXISTS #{@prefix}.#{table}")
    end

    for function <- [
          "trg_ocsf_devices_availability_mirror()",
          "trg_ocsf_devices_availability_legacy()",
          "trg_ocsf_devices_availability_pin_invalidate()",
          "trg_device_agent_availability_consecutive_down()",
          "trg_device_agent_availability_invalidate()",
          "trg_device_vantage_expectations_invalidate()",
          "availability_ledger_ttl(uuid)",
          "availability_projection(boolean)",
          "availability_mode()"
        ] do
      execute("DROP FUNCTION IF EXISTS #{@prefix}.#{function}")
    end

    execute("""
    ALTER TABLE #{@prefix}.ocsf_devices
      DROP CONSTRAINT IF EXISTS ocsf_devices_availability_state_check,
      DROP COLUMN IF EXISTS availability_state,
      DROP COLUMN IF EXISTS availability_decided_by,
      DROP COLUMN IF EXISTS availability_changed_at,
      DROP COLUMN IF EXISTS availability_conflict,
      DROP COLUMN IF EXISTS availability_agents
    """)

    execute(
      "ALTER TABLE #{@prefix}.device_agent_availability DROP COLUMN IF EXISTS consecutive_down"
    )

    execute("""
    ALTER TABLE #{@prefix}.integration_sources
      DROP CONSTRAINT IF EXISTS integration_sources_northbound_availability_semantics_check,
      DROP COLUMN IF EXISTS northbound_availability_semantics
    """)
  end

  defp create_settings do
    execute("""
    CREATE TABLE #{@prefix}.availability_settings (
      singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
      mode text NOT NULL DEFAULT 'legacy'
        CHECK (mode IN ('legacy', 'shadow', 'cutover', 'authoritative')),
      updated_at timestamp without time zone NOT NULL DEFAULT #{@now_utc}
    )
    """)

    execute("INSERT INTO #{@prefix}.availability_settings DEFAULT VALUES")

    # A missing row reads as `legacy`, the mode in which every legacy writer is
    # authoritative, so a deleted row can never switch a reader over.
    execute("""
    CREATE FUNCTION #{@prefix}.availability_mode()
    RETURNS text LANGUAGE sql STABLE AS $$
      SELECT COALESCE(
        (SELECT mode FROM #{@prefix}.availability_settings WHERE singleton),
        'legacy'
      )
    $$
    """)

    execute("""
    CREATE FUNCTION #{@prefix}.availability_projection(available boolean)
    RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT CASE available
        WHEN true THEN 'available'
        WHEN false THEN 'unavailable'
        ELSE 'unknown'
      END
    $$
    """)
  end

  defp create_ledger_counter do
    execute("""
    ALTER TABLE #{@prefix}.device_agent_availability
      ADD COLUMN consecutive_down smallint NOT NULL DEFAULT 0
    """)
  end

  defp create_tables do
    execute("""
    CREATE TABLE #{@prefix}.availability_invalidations (
      id bigserial PRIMARY KEY,
      device_uid text NOT NULL,
      enqueued_at timestamp without time zone NOT NULL DEFAULT #{@now_utc}
    )
    """)

    execute("""
    CREATE TABLE #{@prefix}.device_availability_evidence (
      device_uid text NOT NULL
        REFERENCES #{@prefix}.ocsf_devices (uid) ON DELETE CASCADE,
      source_kind text NOT NULL,
      source_instance text NOT NULL DEFAULT '',
      reporter_agent_id text NOT NULL DEFAULT '',
      authority_class text NOT NULL CHECK (authority_class IN #{@classes}),
      state text NOT NULL CHECK (state IN ('up', 'down')),
      observed_at timestamp without time zone NOT NULL,
      expires_at timestamp without time zone NOT NULL,
      state_since timestamp without time zone NOT NULL,
      confirmations smallint NOT NULL DEFAULT 1 CHECK (confirmations >= 1),
      reporter_eligible boolean NOT NULL DEFAULT true,
      detail jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (octet_length(detail::text) <= 2048),
      updated_at timestamp without time zone NOT NULL DEFAULT #{@now_utc},
      PRIMARY KEY (device_uid, source_kind, source_instance, reporter_agent_id),
      CONSTRAINT device_availability_evidence_up_only_classes
        CHECK (state = 'up' OR authority_class NOT IN ('self_report', 'passive_observation')),
      CONSTRAINT device_availability_evidence_lease
        CHECK (expires_at > observed_at)
    )
    """)

    # The primary key leads with device_uid, so it also serves per-device reads and the
    # cascade from ocsf_devices.
    execute("""
    CREATE INDEX device_availability_evidence_expires_at_idx
      ON #{@prefix}.device_availability_evidence (expires_at)
    """)

    execute("""
    CREATE TABLE #{@prefix}.device_vantage_expectations (
      device_uid text NOT NULL
        REFERENCES #{@prefix}.ocsf_devices (uid) ON DELETE CASCADE,
      agent_id text NOT NULL,
      check_id uuid NOT NULL
        REFERENCES #{@prefix}.composite_checks (id) ON DELETE CASCADE,
      expectation text NOT NULL CHECK (expectation IN ('reachable', 'blocked')),
      updated_at timestamp without time zone NOT NULL DEFAULT #{@now_utc},
      PRIMARY KEY (device_uid, agent_id, check_id)
    )
    """)

    execute("""
    CREATE INDEX device_vantage_expectations_check_id_idx
      ON #{@prefix}.device_vantage_expectations (check_id)
    """)

    execute("""
    CREATE TABLE #{@prefix}.device_availability_shadow (
      device_uid text PRIMARY KEY
        REFERENCES #{@prefix}.ocsf_devices (uid) ON DELETE CASCADE,
      availability_state text NOT NULL CHECK (availability_state IN #{@states}),
      decided_by jsonb,
      conflict boolean NOT NULL DEFAULT false,
      agents jsonb,
      computed_at timestamp without time zone NOT NULL DEFAULT #{@now_utc}
    )
    """)

    execute("""
    CREATE TABLE #{@prefix}.device_availability_legacy (
      device_uid text PRIMARY KEY
        REFERENCES #{@prefix}.ocsf_devices (uid) ON DELETE CASCADE,
      is_available boolean,
      updated_at timestamp without time zone NOT NULL DEFAULT #{@now_utc}
    )
    """)
  end

  defp alter_devices do
    # Constant defaults and nullable columns: catalog-only, no table rewrite. The CHECK is
    # NOT VALID so adding it does not scan the table; every existing row holds the
    # constant default, and new writes are checked.
    execute("""
    ALTER TABLE #{@prefix}.ocsf_devices
      ADD COLUMN availability_state text NOT NULL DEFAULT 'unknown',
      ADD COLUMN availability_decided_by jsonb,
      ADD COLUMN availability_changed_at timestamp without time zone,
      ADD COLUMN availability_conflict boolean NOT NULL DEFAULT false,
      ADD COLUMN availability_agents jsonb
    """)

    execute("""
    ALTER TABLE #{@prefix}.ocsf_devices
      ADD CONSTRAINT ocsf_devices_availability_state_check
      CHECK (availability_state IN #{@states}) NOT VALID
    """)
  end

  defp create_device_triggers do
    # The mirror: while legacy writers are authoritative, availability_state is the
    # projection of is_available. WHEN-guarded so plpgsql runs only for a row whose state
    # disagrees with its projection.
    execute("""
    CREATE FUNCTION #{@prefix}.trg_ocsf_devices_availability_mirror()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{@prefix}.availability_mode() NOT IN ('legacy', 'shadow') THEN
        RETURN NEW;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        NEW.availability_decided_by := jsonb_build_object(
          'rule', 'legacy_mirror',
          'previous', jsonb_build_object(
            'state', OLD.availability_state,
            'changed_at', OLD.availability_changed_at
          )
        );
      ELSE
        NEW.availability_decided_by := jsonb_build_object('rule', 'legacy_mirror');
      END IF;

      NEW.availability_state := #{@prefix}.availability_projection(NEW.is_available);
      NEW.availability_changed_at := #{@now_utc};
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_ocsf_devices_availability_mirror
    BEFORE INSERT OR UPDATE OF is_available, availability_state ON #{@prefix}.ocsf_devices
    FOR EACH ROW
    WHEN (NEW.availability_state IS DISTINCT FROM #{@prefix}.availability_projection(NEW.is_available))
    EXECUTE FUNCTION #{@prefix}.trg_ocsf_devices_availability_mirror()
    """)

    # The compatibility table follows the value the legacy writers computed, written only
    # when it changes. The row is keyed by the device the statement already holds.
    execute("""
    CREATE FUNCTION #{@prefix}.trg_ocsf_devices_availability_legacy()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{@prefix}.availability_mode() IN ('legacy', 'shadow') THEN
        INSERT INTO #{@prefix}.device_availability_legacy AS legacy
          (device_uid, is_available, updated_at)
        VALUES (NEW.uid, NEW.is_available, #{@now_utc})
        ON CONFLICT (device_uid) DO UPDATE
          SET is_available = EXCLUDED.is_available,
              updated_at = EXCLUDED.updated_at
          WHERE legacy.is_available IS DISTINCT FROM EXCLUDED.is_available;
      END IF;

      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_ocsf_devices_availability_legacy_insert
    AFTER INSERT ON #{@prefix}.ocsf_devices
    FOR EACH ROW EXECUTE FUNCTION #{@prefix}.trg_ocsf_devices_availability_legacy()
    """)

    execute("""
    CREATE TRIGGER trg_ocsf_devices_availability_legacy_update
    AFTER UPDATE OF is_available ON #{@prefix}.ocsf_devices
    FOR EACH ROW WHEN (OLD.is_available IS DISTINCT FROM NEW.is_available)
    EXECUTE FUNCTION #{@prefix}.trg_ocsf_devices_availability_legacy()
    """)

    # A pin change re-resolves the device. Availability source profiles reach this too:
    # the profile materializer writes the profile's agent into this column.
    execute("""
    CREATE FUNCTION #{@prefix}.trg_ocsf_devices_availability_pin_invalidate()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{@prefix}.availability_mode() <> 'legacy' THEN
        INSERT INTO #{@prefix}.availability_invalidations (device_uid) VALUES (NEW.uid);
      END IF;

      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_ocsf_devices_availability_pin_invalidate
    AFTER UPDATE OF availability_source_agent_id ON #{@prefix}.ocsf_devices
    FOR EACH ROW
    WHEN (OLD.availability_source_agent_id IS DISTINCT FROM NEW.availability_source_agent_id)
    EXECUTE FUNCTION #{@prefix}.trg_ocsf_devices_availability_pin_invalidate()
    """)
  end

  defp create_ledger_triggers do
    # Freshness of a ledger row: 2 x its sweep group's interval + 5 min, or 2 h for a row
    # without a group (validation scans, legacy rows) or with an interval that is not
    # `<n><s|m|h|d>`.
    execute("""
    CREATE FUNCTION #{@prefix}.availability_ledger_ttl(group_id uuid)
    RETURNS interval LANGUAGE sql STABLE AS $$
      SELECT COALESCE(
        (
          SELECT 2 * (substring(g."interval" FROM '^([0-9]{1,9})')::bigint *
                     CASE lower(right(g."interval", 1))
                       WHEN 's' THEN interval '1 second'
                       WHEN 'm' THEN interval '1 minute'
                       WHEN 'h' THEN interval '1 hour'
                       ELSE interval '1 day'
                     END) + interval '5 minutes'
          FROM #{@prefix}.sweep_groups AS g
          WHERE g.id = group_id AND g."interval" ~* '^[0-9]{1,9}[smhd]$'
        ),
        interval '2 hours'
      )
    $$
    """)

    # The active_probe confirmation threshold is 2, the sweep ingestor's
    # @unavailable_threshold. A new observation is a later checked_at; any other update
    # (merge reassignment, a replayed result, the backfill) keeps the statement's value.
    execute("""
    CREATE FUNCTION #{@prefix}.trg_device_agent_availability_consecutive_down()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        NEW.consecutive_down := CASE WHEN NEW.is_available THEN 0 ELSE 1 END;
      ELSIF NEW.checked_at > OLD.checked_at THEN
        NEW.consecutive_down := CASE
          WHEN NEW.is_available THEN 0
          WHEN OLD.is_available THEN 1
          ELSE LEAST(OLD.consecutive_down + 1, 2)
        END;
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_device_agent_availability_consecutive_down
    BEFORE INSERT OR UPDATE ON #{@prefix}.device_agent_availability
    FOR EACH ROW EXECUTE FUNCTION #{@prefix}.trg_device_agent_availability_consecutive_down()
    """)

    # Appends only when the stored result can change a decision: a new row, a moved row,
    # a changed result, counter, group or reporter eligibility, or a renewal of a row that
    # was older than half its freshness window. A steady renewal of a fresh row appends
    # nothing. The checks that need no read run first.
    execute("""
    CREATE FUNCTION #{@prefix}.trg_device_agent_availability_invalidate()
    RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      now_utc timestamp without time zone := #{@now_utc};
    BEGIN
      IF TG_OP = 'INSERT'
         OR NEW.device_uid IS DISTINCT FROM OLD.device_uid
         OR NEW.is_available IS DISTINCT FROM OLD.is_available
         OR NEW.consecutive_down IS DISTINCT FROM OLD.consecutive_down
         OR NEW.sweep_group_id IS DISTINCT FROM OLD.sweep_group_id
         OR (NEW.metadata ->> 'sweep_reporter_expectation')
              IS DISTINCT FROM (OLD.metadata ->> 'sweep_reporter_expectation')
         OR (OLD.checked_at < now_utc - interval '150 seconds'
             AND OLD.checked_at <
                 now_utc - #{@prefix}.availability_ledger_ttl(NEW.sweep_group_id) / 2)
      THEN
        IF #{@prefix}.availability_mode() <> 'legacy' THEN
          INSERT INTO #{@prefix}.availability_invalidations (device_uid)
          VALUES (NEW.device_uid);
        END IF;
      END IF;

      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_device_agent_availability_invalidate
    AFTER INSERT OR UPDATE ON #{@prefix}.device_agent_availability
    FOR EACH ROW EXECUTE FUNCTION #{@prefix}.trg_device_agent_availability_invalidate()
    """)
  end

  defp create_expectation_triggers do
    execute("""
    CREATE FUNCTION #{@prefix}.trg_device_vantage_expectations_invalidate()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{@prefix}.availability_mode() = 'legacy' THEN
        RETURN NULL;
      END IF;

      IF TG_OP = 'INSERT' THEN
        INSERT INTO #{@prefix}.availability_invalidations (device_uid) VALUES (NEW.device_uid);
      ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO #{@prefix}.availability_invalidations (device_uid) VALUES (OLD.device_uid);
      ELSE
        INSERT INTO #{@prefix}.availability_invalidations (device_uid) VALUES (OLD.device_uid);

        IF NEW.device_uid IS DISTINCT FROM OLD.device_uid THEN
          INSERT INTO #{@prefix}.availability_invalidations (device_uid) VALUES (NEW.device_uid);
        END IF;
      END IF;

      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_device_vantage_expectations_invalidate_insert_delete
    AFTER INSERT OR DELETE ON #{@prefix}.device_vantage_expectations
    FOR EACH ROW EXECUTE FUNCTION #{@prefix}.trg_device_vantage_expectations_invalidate()
    """)

    execute("""
    CREATE TRIGGER trg_device_vantage_expectations_invalidate_update
    AFTER UPDATE ON #{@prefix}.device_vantage_expectations
    FOR EACH ROW
    WHEN (OLD.expectation IS DISTINCT FROM NEW.expectation
          OR OLD.device_uid IS DISTINCT FROM NEW.device_uid)
    EXECUTE FUNCTION #{@prefix}.trg_device_vantage_expectations_invalidate()
    """)

    # Disabling a check, or returning it to draft, removes its expectations whichever path
    # changed the state. Deleting it cascades through the foreign key.
    execute("""
    CREATE FUNCTION #{@prefix}.trg_composite_checks_clear_vantage_expectations()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      DELETE FROM #{@prefix}.device_vantage_expectations WHERE check_id = NEW.id;
      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_composite_checks_clear_vantage_expectations
    AFTER UPDATE OF state ON #{@prefix}.composite_checks
    FOR EACH ROW
    WHEN (NEW.state <> 'enabled' AND OLD.state IS DISTINCT FROM NEW.state)
    EXECUTE FUNCTION #{@prefix}.trg_composite_checks_clear_vantage_expectations()
    """)
  end

  defp alter_integration_sources do
    execute("""
    ALTER TABLE #{@prefix}.integration_sources
      ADD COLUMN northbound_availability_semantics text NOT NULL DEFAULT 'legacy',
      ADD CONSTRAINT integration_sources_northbound_availability_semantics_check
        CHECK (northbound_availability_semantics IN ('legacy', 'merged'))
    """)
  end
end
