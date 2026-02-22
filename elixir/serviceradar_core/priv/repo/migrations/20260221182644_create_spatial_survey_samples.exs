defmodule ServiceRadar.Repo.Migrations.CreateSpatialSurveySamples do
  use Ecto.Migration
  @rf_vector_dims 64
  @ble_vector_dims 64

  def up do
    # Enable PostGIS and pgvector extensions
    execute "CREATE EXTENSION IF NOT EXISTS postgis;"
    execute "CREATE EXTENSION IF NOT EXISTS vector;"

    create table(:survey_samples, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :session_id, :text, null: false
      add :scanner_device_id, :text, null: false
      add :timestamp, :utc_datetime_usec, null: false

      add :bssid, :text, null: false
      add :ssid, :text, null: false
      add :rssi, :float, null: false
      add :frequency, :integer, null: false
      add :security_type, :text
      add :is_secure, :boolean

      add :x, :float, null: false
      add :y, :float, null: false
      add :z, :float, null: false
      add :uncertainty, :float

      add :latitude, :float
      add :longitude, :float

      # We define them as vectors to take advantage of pgvector type
      add :rf_vector, :vector
      add :ble_vector, :vector
    end

    execute "ALTER TABLE platform.survey_samples ADD PRIMARY KEY (timestamp, id);"

    # Optional TimescaleDB configuration
    execute "SELECT create_hypertable('platform.survey_samples', 'timestamp', if_not_exists => TRUE);"

    execute(
      "ALTER TABLE platform.survey_samples ALTER COLUMN rf_vector TYPE vector(#{@rf_vector_dims})"
    )

    execute(
      "ALTER TABLE platform.survey_samples ALTER COLUMN ble_vector TYPE vector(#{@ble_vector_dims})"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS survey_samples_rf_vector_idx ON platform.survey_samples USING hnsw (rf_vector vector_cosine_ops);"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS survey_samples_ble_vector_idx ON platform.survey_samples USING hnsw (ble_vector vector_cosine_ops);"
    )

    create index(:survey_samples, [:session_id], prefix: "platform")
    create index(:survey_samples, [:bssid], prefix: "platform")
  end

  def down do
    drop table(:survey_samples, prefix: "platform")
  end
end
