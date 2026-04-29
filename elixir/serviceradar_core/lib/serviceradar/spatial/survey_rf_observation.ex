defmodule ServiceRadar.Spatial.SurveyRfObservation do
  @moduledoc """
  Raw RF observations captured by FieldSurvey Sidekick monitor-mode radios.
  """
  use Ash.Resource,
    domain: ServiceRadar.Spatial,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("survey_rf_observations")
    repo(ServiceRadar.Repo)
  end

  actions do
    defaults([:read, :destroy])

    action :bulk_insert, :boolean do
      argument(:session_id, :string, allow_nil?: false)
      argument(:observations, {:array, :map}, allow_nil?: false)

      run(ServiceRadar.Spatial.Actions.BulkInsertRfObservations)
    end
  end

  attributes do
    uuid_primary_key(:id)

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

    attribute(:captured_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:captured_at_unix_nanos, :integer, allow_nil?: false)
    attribute(:captured_at_monotonic_nanos, :integer)
    attribute(:parser_confidence, :float, allow_nil?: false)
    attribute(:inserted_at, :utc_datetime_usec, allow_nil?: false)
  end
end
