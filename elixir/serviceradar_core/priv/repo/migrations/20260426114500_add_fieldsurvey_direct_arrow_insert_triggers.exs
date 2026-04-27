defmodule ServiceRadar.Repo.Migrations.AddFieldSurveyDirectArrowInsertTriggers do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE FUNCTION platform.fieldsurvey_unix_nanos_to_timestamptz(unix_nanos bigint)
    RETURNS timestamptz
    LANGUAGE sql
    IMMUTABLE
    AS $$
      SELECT TIMESTAMPTZ 'epoch' + (($1::numeric / 1000000000.0) * INTERVAL '1 second');
    $$;
    """

    execute """
    CREATE OR REPLACE FUNCTION platform.fieldsurvey_clamp(value double precision, min_value double precision, max_value double precision)
    RETURNS double precision
    LANGUAGE sql
    IMMUTABLE
    AS $$
      SELECT GREATEST(LEAST($1, $3), $2);
    $$;
    """

    execute """
    CREATE OR REPLACE FUNCTION platform.prepare_survey_rf_observation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      trusted_session_id text := current_setting('serviceradar.field_survey_session_id', true);
    BEGIN
      IF trusted_session_id IS NOT NULL AND trusted_session_id <> '' THEN
        NEW.session_id := trusted_session_id;
      END IF;

      IF NEW.session_id IS NULL OR NEW.session_id = '' THEN
        RAISE EXCEPTION 'FieldSurvey RF observation missing trusted session_id';
      END IF;

      NEW.captured_at := platform.fieldsurvey_unix_nanos_to_timestamptz(NEW.captured_at_unix_nanos);
      NEW.inserted_at := now();
      NEW.rf_features := format(
        '[%s,%s,%s,%s,%s,%s,%s,%s]',
        platform.fieldsurvey_clamp(COALESCE(NEW.rssi_dbm, -128)::double precision / 128.0, -1.0, 1.0),
        platform.fieldsurvey_clamp(COALESCE(NEW.noise_floor_dbm, -128)::double precision / 128.0, -1.0, 1.0),
        platform.fieldsurvey_clamp(COALESCE(NEW.snr_db, 0)::double precision / 128.0, -1.0, 1.0),
        platform.fieldsurvey_clamp(NEW.frequency_mhz::double precision / 7125.0, 0.0, 1.0),
        platform.fieldsurvey_clamp(COALESCE(NEW.channel, 0)::double precision / 233.0, 0.0, 1.0),
        platform.fieldsurvey_clamp(COALESCE(NEW.channel_width_mhz, 0)::double precision / 320.0, 0.0, 1.0),
        CASE WHEN NEW.hidden_ssid THEN 1.0 ELSE 0.0 END,
        platform.fieldsurvey_clamp(COALESCE(NEW.parser_confidence, 0.0)::double precision, 0.0, 1.0)
      )::vector(8);

      RETURN NEW;
    END;
    $$;
    """

    execute """
    CREATE OR REPLACE FUNCTION platform.prepare_survey_pose_sample()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      trusted_session_id text := current_setting('serviceradar.field_survey_session_id', true);
    BEGIN
      IF trusted_session_id IS NOT NULL AND trusted_session_id <> '' THEN
        NEW.session_id := trusted_session_id;
      END IF;

      IF NEW.session_id IS NULL OR NEW.session_id = '' THEN
        RAISE EXCEPTION 'FieldSurvey pose sample missing trusted session_id';
      END IF;

      NEW.captured_at := platform.fieldsurvey_unix_nanos_to_timestamptz(NEW.captured_at_unix_nanos);
      NEW.inserted_at := now();

      RETURN NEW;
    END;
    $$;
    """

    execute """
    CREATE OR REPLACE FUNCTION platform.prepare_survey_spectrum_observation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      trusted_session_id text := current_setting('serviceradar.field_survey_session_id', true);
      min_power double precision;
      max_power double precision;
      avg_power double precision;
      stddev_power double precision;
      bin_count integer;
    BEGIN
      IF trusted_session_id IS NOT NULL AND trusted_session_id <> '' THEN
        NEW.session_id := trusted_session_id;
      END IF;

      IF NEW.session_id IS NULL OR NEW.session_id = '' THEN
        RAISE EXCEPTION 'FieldSurvey spectrum observation missing trusted session_id';
      END IF;

      NEW.started_at := platform.fieldsurvey_unix_nanos_to_timestamptz(NEW.started_at_unix_nanos);
      NEW.captured_at := platform.fieldsurvey_unix_nanos_to_timestamptz(NEW.captured_at_unix_nanos);
      NEW.inserted_at := now();

      SELECT
        MIN(value)::double precision,
        MAX(value)::double precision,
        AVG(value)::double precision,
        COALESCE(STDDEV_POP(value), 0.0)::double precision,
        COUNT(*)::integer
      INTO min_power, max_power, avg_power, stddev_power, bin_count
      FROM unnest(NEW.power_bins_dbm) AS value;

      NEW.power_features := format(
        '[%s,%s,%s,%s,%s,%s,%s,%s]',
        platform.fieldsurvey_clamp(COALESCE(avg_power, -120.0) / 120.0, -1.0, 1.0),
        platform.fieldsurvey_clamp(COALESCE(max_power, -120.0) / 120.0, -1.0, 1.0),
        platform.fieldsurvey_clamp(COALESCE(min_power, -120.0) / 120.0, -1.0, 1.0),
        platform.fieldsurvey_clamp(COALESCE(stddev_power, 0.0) / 40.0, 0.0, 1.0),
        platform.fieldsurvey_clamp((NEW.stop_frequency_hz - NEW.start_frequency_hz)::double precision / 8000000000.0, 0.0, 1.0),
        platform.fieldsurvey_clamp(NEW.bin_width_hz::double precision / 20000000.0, 0.0, 1.0),
        platform.fieldsurvey_clamp(NEW.sample_count::double precision / 4096.0, 0.0, 1.0),
        platform.fieldsurvey_clamp(COALESCE(bin_count, 0)::double precision / 4096.0, 0.0, 1.0)
      )::vector(8);

      RETURN NEW;
    END;
    $$;
    """

    execute "DROP TRIGGER IF EXISTS prepare_survey_rf_observation_insert ON platform.survey_rf_observations;"
    execute "DROP TRIGGER IF EXISTS prepare_survey_pose_sample_insert ON platform.survey_pose_samples;"
    execute "DROP TRIGGER IF EXISTS prepare_survey_spectrum_observation_insert ON platform.survey_spectrum_observations;"

    execute """
    CREATE TRIGGER prepare_survey_rf_observation_insert
    BEFORE INSERT ON platform.survey_rf_observations
    FOR EACH ROW
    EXECUTE FUNCTION platform.prepare_survey_rf_observation();
    """

    execute """
    CREATE TRIGGER prepare_survey_pose_sample_insert
    BEFORE INSERT ON platform.survey_pose_samples
    FOR EACH ROW
    EXECUTE FUNCTION platform.prepare_survey_pose_sample();
    """

    execute """
    CREATE TRIGGER prepare_survey_spectrum_observation_insert
    BEFORE INSERT ON platform.survey_spectrum_observations
    FOR EACH ROW
    EXECUTE FUNCTION platform.prepare_survey_spectrum_observation();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS prepare_survey_spectrum_observation_insert ON platform.survey_spectrum_observations;"
    execute "DROP TRIGGER IF EXISTS prepare_survey_pose_sample_insert ON platform.survey_pose_samples;"
    execute "DROP TRIGGER IF EXISTS prepare_survey_rf_observation_insert ON platform.survey_rf_observations;"

    execute "DROP FUNCTION IF EXISTS platform.prepare_survey_spectrum_observation();"
    execute "DROP FUNCTION IF EXISTS platform.prepare_survey_pose_sample();"
    execute "DROP FUNCTION IF EXISTS platform.prepare_survey_rf_observation();"
    execute "DROP FUNCTION IF EXISTS platform.fieldsurvey_clamp(double precision, double precision, double precision);"
    execute "DROP FUNCTION IF EXISTS platform.fieldsurvey_unix_nanos_to_timestamptz(bigint);"
  end
end
