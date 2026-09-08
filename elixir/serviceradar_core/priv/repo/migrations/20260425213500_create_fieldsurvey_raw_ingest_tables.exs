defmodule ServiceRadar.Repo.Migrations.CreateFieldSurveyRawIngestTables do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS postgis;"
    execute "CREATE EXTENSION IF NOT EXISTS vector;"

    create table(:survey_rf_observations, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :session_id, :text, null: false
      add :sidekick_id, :text, null: false
      add :radio_id, :text, null: false
      add :interface_name, :text, null: false

      add :bssid, :text, null: false
      add :ssid, :text
      add :hidden_ssid, :boolean, null: false, default: true
      add :frame_type, :text, null: false

      add :rssi_dbm, :smallint
      add :noise_floor_dbm, :smallint
      add :snr_db, :smallint
      add :frequency_mhz, :integer, null: false
      add :channel, :integer
      add :channel_width_mhz, :integer

      add :captured_at, :timestamptz, null: false
      add :captured_at_unix_nanos, :bigint, null: false
      add :captured_at_monotonic_nanos, :bigint
      add :parser_confidence, :float, null: false, default: 0.0
      add :rf_features, :vector
      add :inserted_at, :timestamptz, null: false
    end

    execute "ALTER TABLE platform.survey_rf_observations ADD PRIMARY KEY (captured_at, id);"
    execute "ALTER TABLE platform.survey_rf_observations ALTER COLUMN rf_features TYPE vector(8);"

    execute("SELECT create_hypertable('platform.survey_rf_observations', 'captured_at', if_not_exists => TRUE);")

    create index(:survey_rf_observations, [:session_id, :captured_at],
             prefix: "platform",
             name: :survey_rf_observations_session_time_idx
           )

    create index(:survey_rf_observations, [:session_id, :bssid],
             prefix: "platform",
             name: :survey_rf_observations_session_bssid_idx
           )

    create index(:survey_rf_observations, [:radio_id, :captured_at],
             prefix: "platform",
             name: :survey_rf_observations_radio_time_idx
           )

    execute """
    CREATE INDEX survey_rf_observations_rf_features_idx
    ON platform.survey_rf_observations
    USING hnsw (rf_features vector_cosine_ops)
    WHERE rf_features IS NOT NULL;
    """

    create table(:survey_pose_samples, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :session_id, :text, null: false
      add :scanner_device_id, :text, null: false

      add :captured_at, :timestamptz, null: false
      add :captured_at_unix_nanos, :bigint, null: false
      add :captured_at_monotonic_nanos, :bigint

      add :x, :float, null: false
      add :y, :float, null: false
      add :z, :float, null: false
      add :qx, :float, null: false
      add :qy, :float, null: false
      add :qz, :float, null: false
      add :qw, :float, null: false

      add :latitude, :float
      add :longitude, :float
      add :altitude, :float
      add :accuracy_m, :float
      add :tracking_quality, :text
      add :inserted_at, :timestamptz, null: false
    end

    execute "ALTER TABLE platform.survey_pose_samples ADD PRIMARY KEY (captured_at, id);"

    execute """
    ALTER TABLE platform.survey_pose_samples
    ADD COLUMN position geometry(PointZ, 0)
    GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(x, y, z), 0)) STORED;
    """

    execute """
    ALTER TABLE platform.survey_pose_samples
    ADD COLUMN location geography(Point, 4326)
    GENERATED ALWAYS AS (
      CASE
        WHEN latitude IS NOT NULL AND longitude IS NOT NULL
        THEN ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography
        ELSE NULL
      END
    ) STORED;
    """

    execute("SELECT create_hypertable('platform.survey_pose_samples', 'captured_at', if_not_exists => TRUE);")

    create index(:survey_pose_samples, [:session_id, :captured_at],
             prefix: "platform",
             name: :survey_pose_samples_session_time_idx
           )

    create index(:survey_pose_samples, [:scanner_device_id, :captured_at],
             prefix: "platform",
             name: :survey_pose_samples_scanner_time_idx
           )

    execute """
    CREATE INDEX survey_pose_samples_position_gist_idx
    ON platform.survey_pose_samples
    USING gist (position);
    """

    execute """
    CREATE INDEX survey_pose_samples_location_gist_idx
    ON platform.survey_pose_samples
    USING gist (location)
    WHERE location IS NOT NULL;
    """

    create table(:survey_spectrum_observations, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :session_id, :text, null: false
      add :sidekick_id, :text, null: false
      add :sdr_id, :text, null: false
      add :device_kind, :text, null: false
      add :serial_number, :text
      add :sweep_id, :bigint, null: false

      add :started_at, :timestamptz, null: false
      add :started_at_unix_nanos, :bigint, null: false
      add :captured_at, :timestamptz, null: false
      add :captured_at_unix_nanos, :bigint, null: false

      add :start_frequency_hz, :bigint, null: false
      add :stop_frequency_hz, :bigint, null: false
      add :bin_width_hz, :float, null: false
      add :sample_count, :integer, null: false
      add :power_bins_dbm, {:array, :float}, null: false
      add :power_features, :vector
      add :inserted_at, :timestamptz, null: false
    end

    execute "ALTER TABLE platform.survey_spectrum_observations ADD PRIMARY KEY (captured_at, id);"
    execute "ALTER TABLE platform.survey_spectrum_observations ALTER COLUMN power_features TYPE vector(8);"

    execute("SELECT create_hypertable('platform.survey_spectrum_observations', 'captured_at', if_not_exists => TRUE);")

    create index(:survey_spectrum_observations, [:session_id, :captured_at],
             prefix: "platform",
             name: :survey_spectrum_observations_session_time_idx
           )

    create index(:survey_spectrum_observations, [:sdr_id, :captured_at],
             prefix: "platform",
             name: :survey_spectrum_observations_sdr_time_idx
           )

    execute """
    CREATE INDEX survey_spectrum_observations_power_features_idx
    ON platform.survey_spectrum_observations
    USING hnsw (power_features vector_cosine_ops)
    WHERE power_features IS NOT NULL;
    """

    execute """
    CREATE VIEW platform.survey_rf_pose_matches AS
    SELECT
      rf.id AS rf_observation_id,
      pose.id AS pose_sample_id,
      rf.session_id,
      rf.sidekick_id,
      rf.radio_id,
      rf.interface_name,
      rf.bssid,
      rf.ssid,
      rf.hidden_ssid,
      rf.frame_type,
      rf.rssi_dbm,
      rf.noise_floor_dbm,
      rf.snr_db,
      rf.frequency_mhz,
      rf.channel,
      rf.channel_width_mhz,
      rf.captured_at AS rf_captured_at,
      rf.captured_at_unix_nanos AS rf_captured_at_unix_nanos,
      rf.captured_at_monotonic_nanos AS rf_captured_at_monotonic_nanos,
      pose.scanner_device_id,
      pose.captured_at AS pose_captured_at,
      pose.captured_at_unix_nanos AS pose_captured_at_unix_nanos,
      pose.captured_at_monotonic_nanos AS pose_captured_at_monotonic_nanos,
      ROUND(ABS(EXTRACT(EPOCH FROM (pose.captured_at - rf.captured_at))) * 1000000000)::bigint AS pose_offset_nanos,
      pose.x,
      pose.y,
      pose.z,
      pose.qx,
      pose.qy,
      pose.qz,
      pose.qw,
      pose.latitude,
      pose.longitude,
      pose.altitude,
      pose.accuracy_m,
      pose.tracking_quality,
      pose.position,
      pose.location,
      rf.rf_features
    FROM platform.survey_rf_observations rf
    LEFT JOIN LATERAL (
      SELECT pose.*
      FROM platform.survey_pose_samples pose
      WHERE pose.session_id = rf.session_id
        AND pose.captured_at BETWEEN rf.captured_at - INTERVAL '200 milliseconds'
                                AND rf.captured_at + INTERVAL '200 milliseconds'
      ORDER BY ABS(EXTRACT(EPOCH FROM (pose.captured_at - rf.captured_at))) ASC
      LIMIT 1
    ) pose ON TRUE;
    """
  end

  def down do
    execute "DROP VIEW IF EXISTS platform.survey_rf_pose_matches;"
    drop table(:survey_spectrum_observations, prefix: "platform")
    drop table(:survey_pose_samples, prefix: "platform")
    drop table(:survey_rf_observations, prefix: "platform")
  end
end
