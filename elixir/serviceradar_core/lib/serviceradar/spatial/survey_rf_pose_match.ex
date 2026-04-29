defmodule ServiceRadar.Spatial.SurveyRfPoseMatch do
  @moduledoc """
  Timestamp-fused FieldSurvey RF observations with nearest iPhone pose samples.
  """
  use Ash.Resource,
    domain: ServiceRadar.Spatial,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("survey_rf_pose_matches")
    repo(ServiceRadar.Repo)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute(:rf_observation_id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:pose_sample_id, :uuid)
    attribute(:session_id, :string, allow_nil?: false)
    attribute(:sidekick_id, :string, allow_nil?: false)
    attribute(:radio_id, :string, allow_nil?: false)
    attribute(:interface_name, :string, allow_nil?: false)

    attribute(:bssid, :string, allow_nil?: false)
    attribute(:ssid, :string)
    attribute(:hidden_ssid, :boolean, allow_nil?: false)
    attribute(:frame_type, :string, allow_nil?: false)

    attribute(:rssi_dbm, :integer)
    attribute(:noise_floor_dbm, :integer)
    attribute(:snr_db, :integer)
    attribute(:frequency_mhz, :integer, allow_nil?: false)
    attribute(:channel, :integer)
    attribute(:channel_width_mhz, :integer)

    attribute(:rf_captured_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:rf_captured_at_unix_nanos, :integer, allow_nil?: false)
    attribute(:rf_captured_at_monotonic_nanos, :integer)
    attribute(:scanner_device_id, :string)
    attribute(:pose_captured_at, :utc_datetime_usec)
    attribute(:pose_captured_at_unix_nanos, :integer)
    attribute(:pose_captured_at_monotonic_nanos, :integer)
    attribute(:pose_offset_nanos, :integer)

    attribute(:x, :float)
    attribute(:y, :float)
    attribute(:z, :float)
    attribute(:qx, :float)
    attribute(:qy, :float)
    attribute(:qz, :float)
    attribute(:qw, :float)
    attribute(:latitude, :float)
    attribute(:longitude, :float)
    attribute(:altitude, :float)
    attribute(:accuracy_m, :float)
    attribute(:tracking_quality, :string)
  end
end
