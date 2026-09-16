defmodule ServiceRadar.Repo.Migrations.CreateChronologicalSeasonalDispositionStates do
  @moduledoc """
  Starts chronological confirmation from zero without losing prior window verdicts.

  Legacy counters combined repeated evaluations and separate weeks. Their values
  cannot be converted to consecutive hourly windows. A separate table prevents an
  older worker from overwriting new confirmation progress during a rolling upgrade.
  Copying only missing rows makes retries preserve every newly evaluated window,
  including zero counters, while retaining terminal breach history for clearing.

  The migration transaction locks the legacy table before copying and resetting it.
  A write fence then rejects older workers, whose persist-before-publish contract
  prevents new verdicts based on legacy counters. Their jobs retry on upgraded workers.
  Reads and expiry cleanup remain available. Jobs that persisted before the lock may
  still publish, so an operational rollout should drain seasonal jobs before migration.

  Source names are copied verbatim, including custom names. Fresh deployments copy
  no rows. Rollback requires both the application and this migration to be reverted:
  `down/0` removes the legacy write fence but keeps chronological state, allowing a
  later upgrade to retain confirmation progress instead of resetting it again.
  """

  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - finite confirmation state only, never
    # telemetry. Inserts missing state rows with zero counters, then resets only the
    # retired table. Replaying this migration cannot change chronological progress.
    Enum.each(upgrade_statements(), &execute/1)
  end

  def down do
    Enum.each(rollback_statements(), &execute/1)
  end

  @doc false
  def upgrade_statements do
    [
      "LOCK TABLE platform.seasonal_disposition_states IN SHARE ROW EXCLUSIVE MODE",
      drop_fence_sql(),
      """
      CREATE TABLE IF NOT EXISTS platform.seasonal_disposition_chronological_states (
        source text NOT NULL,
        series_key text NOT NULL,
        dow integer NOT NULL CHECK (dow >= 0 AND dow <= 6),
        hod integer NOT NULL CHECK (hod >= 0 AND hod <= 23),
        consecutive_anomalous integer NOT NULL DEFAULT 0 CHECK (consecutive_anomalous >= 0),
        last_disposition text,
        last_status text,
        last_score double precision,
        last_evaluated_at timestamp(6) without time zone,
        last_bucket_started_at timestamp(6) without time zone,
        last_bucket_ended_at timestamp(6) without time zone,
        expires_at timestamp(6) without time zone NOT NULL,
        inserted_at timestamp(6) without time zone NOT NULL,
        updated_at timestamp(6) without time zone NOT NULL,
        PRIMARY KEY (source, series_key, dow, hod)
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS seasonal_chronological_states_expires_idx
      ON platform.seasonal_disposition_chronological_states (expires_at)
      """,
      """
      CREATE INDEX IF NOT EXISTS seasonal_chronological_states_series_window_idx
      ON platform.seasonal_disposition_chronological_states (source, series_key, last_bucket_started_at)
      """,
      reset_sql(),
      """
      CREATE OR REPLACE FUNCTION platform.reject_legacy_seasonal_disposition_writes()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $function$
      BEGIN
        RAISE EXCEPTION USING
          ERRCODE = '55000',
          MESSAGE = 'Legacy seasonal confirmation writes are disabled; upgrade the seasonal disposition worker',
          HINT = 'Retry this job on an upgraded worker using seasonal_disposition_chronological_states.';
      END;
      $function$
      """,
      """
      CREATE TRIGGER reject_legacy_seasonal_disposition_writes
      BEFORE INSERT OR UPDATE ON platform.seasonal_disposition_states
      FOR EACH ROW EXECUTE FUNCTION platform.reject_legacy_seasonal_disposition_writes()
      """
    ]
  end

  @doc false
  def rollback_statements do
    [
      drop_fence_sql(),
      "DROP FUNCTION IF EXISTS platform.reject_legacy_seasonal_disposition_writes()"
    ]
  end

  defp drop_fence_sql do
    """
    DROP TRIGGER IF EXISTS reject_legacy_seasonal_disposition_writes
    ON platform.seasonal_disposition_states
    """
  end

  defp reset_sql do
    """
    WITH copied AS (
      INSERT INTO platform.seasonal_disposition_chronological_states (
        source, series_key, dow, hod, consecutive_anomalous,
        last_disposition, last_status, last_score, last_evaluated_at,
        last_bucket_started_at, last_bucket_ended_at, expires_at,
        inserted_at, updated_at
      )
      SELECT source, series_key, dow, hod, 0,
             last_disposition, last_status, last_score, last_evaluated_at,
             last_bucket_started_at, last_bucket_ended_at, expires_at,
             inserted_at, updated_at
      FROM platform.seasonal_disposition_states
      ON CONFLICT (source, series_key, dow, hod) DO NOTHING
      RETURNING source
    )
    UPDATE platform.seasonal_disposition_states
    SET consecutive_anomalous = 0
    WHERE consecutive_anomalous <> 0
    """
  end
end
