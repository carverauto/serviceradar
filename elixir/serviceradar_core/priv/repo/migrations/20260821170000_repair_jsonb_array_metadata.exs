defmodule ServiceRadar.Repo.Migrations.RepairJsonbArrayMetadata do
  @moduledoc """
  Flatten `metadata` columns that were turned into a JSON **array** by a
  double-encoded jsonb parameter.

  `SourceIdentityDrift.apply_armis_metadata_repairs/2` passed
  `Jason.encode!(patch)` to a `$2::jsonb` placeholder. Postgres types such a
  placeholder as `jsonb`, so Postgrex ran the already-encoded binary through
  its own JSON encoder a second time and stored a jsonb **string scalar**.
  Postgres `||` does not merge an object with a scalar, it builds an array:

      '{"a":1}'::jsonb || '"{\\"b\\":2}"'::jsonb  ->  [{"a": 1}, "{\\"b\\":2}"]

  Every later Armis sync then did `metadata || <object>`, and `array || object`
  appends, so the column drifted further from an object with each run. Reading
  such a device raises `ArgumentError: cannot load [...] as type :map`, which
  took the whole Armis discovery sync down (status `Failed`, climbing
  consecutive-failure count).

  The writers are fixed to pass maps; this repairs rows already written. Each
  array is folded back into an object in element order so later elements win,
  which is exactly what the `||` chain would have produced had the parameter
  been encoded once. Embedded JSON-object strings are parsed and merged, so the
  repaired Armis identifiers are preserved rather than discarded. Elements that
  carry no keys (unparseable strings, nested arrays, numbers) are dropped -- a
  bad scalar must not abort the migration for every other row.

  The two blocks below are deliberately spelled out per table rather than
  generated from a table list. Building the statement with string interpolation
  would hide `UPDATE platform.<table>` from
  `scripts/db/check-migration-startup-safety.sh`, which greps the migration
  source: this repair is exactly the kind of maintenance that gate exists to
  catch, so it should be visible to it and carry an explicit waiver.
  """

  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - a data repair cannot be deferred
    # to a post-bootstrap job here: while a row's metadata is an array, ANY read
    # of that device raises, so the Armis sync (and anything else touching the
    # row) stays broken until it is fixed. Deferring it would mean shipping the
    # code fix and leaving the customer's integration down.
    #
    # Bounded by construction rather than by a measured row count: the WHERE
    # only matches rows that are ALREADY broken, so a healthy or freshly
    # installed database matches zero rows and the block is a no-op. The
    # corrupting writer capped each pass at @default_repair_limit (5_000)
    # devices. We do not have access to the affected cluster, so the live count
    # is unverified -- operators upgrading a cluster with a large corrupt set
    # should raise `helm upgrade --timeout` above its 5m default, because this
    # runs in the `serviceradar-core-migrations` pre-upgrade hook.
    execute(repair_ocsf_devices())
    execute(repair_survey_session_metadata())
  end

  # Irreversible by nature: the array shape was corruption, never a valid
  # state, and the pre-repair element boundaries are not recoverable from the
  # merged object. Re-running `up` is safe, so `down` is a no-op rather than a
  # migration that would have to re-corrupt the data.
  def down, do: :ok

  defp repair_ocsf_devices do
    """
    DO $repair$
    DECLARE
      row_rec  record;
      element  jsonb;
      merged   jsonb;
      parsed   jsonb;
      repaired int := 0;
    BEGIN
      IF to_regclass('platform.ocsf_devices') IS NULL THEN
        RAISE NOTICE 'platform.ocsf_devices does not exist, skipping';
        RETURN;
      END IF;

      FOR row_rec IN
        SELECT uid AS row_key, metadata
        FROM platform.ocsf_devices
        WHERE jsonb_typeof(metadata) = 'array'
      LOOP
        merged := '{}'::jsonb;

        FOR element IN SELECT value FROM jsonb_array_elements(row_rec.metadata)
        LOOP
          IF jsonb_typeof(element) = 'object' THEN
            merged := merged || element;
          ELSIF jsonb_typeof(element) = 'string' THEN
            BEGIN
              parsed := (element #>> '{}')::jsonb;
              IF jsonb_typeof(parsed) = 'object' THEN
                merged := merged || parsed;
              END IF;
            EXCEPTION WHEN others THEN
              NULL;
            END;
          END IF;
        END LOOP;

        UPDATE platform.ocsf_devices
        SET metadata = merged
        WHERE uid = row_rec.row_key;

        repaired := repaired + 1;
      END LOOP;

      RAISE NOTICE 'repaired % array-shaped metadata row(s) in platform.ocsf_devices', repaired;
    END
    $repair$;
    """
  end

  defp repair_survey_session_metadata do
    """
    DO $repair$
    DECLARE
      row_rec  record;
      element  jsonb;
      merged   jsonb;
      parsed   jsonb;
      repaired int := 0;
    BEGIN
      IF to_regclass('platform.survey_session_metadata') IS NULL THEN
        RAISE NOTICE 'platform.survey_session_metadata does not exist, skipping';
        RETURN;
      END IF;

      FOR row_rec IN
        SELECT session_id AS row_key, metadata
        FROM platform.survey_session_metadata
        WHERE jsonb_typeof(metadata) = 'array'
      LOOP
        merged := '{}'::jsonb;

        FOR element IN SELECT value FROM jsonb_array_elements(row_rec.metadata)
        LOOP
          IF jsonb_typeof(element) = 'object' THEN
            merged := merged || element;
          ELSIF jsonb_typeof(element) = 'string' THEN
            BEGIN
              parsed := (element #>> '{}')::jsonb;
              IF jsonb_typeof(parsed) = 'object' THEN
                merged := merged || parsed;
              END IF;
            EXCEPTION WHEN others THEN
              NULL;
            END;
          END IF;
        END LOOP;

        UPDATE platform.survey_session_metadata
        SET metadata = merged
        WHERE session_id = row_rec.row_key;

        repaired := repaired + 1;
      END LOOP;

      RAISE NOTICE 'repaired % array-shaped metadata row(s) in platform.survey_session_metadata', repaired;
    END
    $repair$;
    """
  end
end
