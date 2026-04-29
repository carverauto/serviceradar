defmodule ServiceRadar.Spatial.SurveySpectrumObservation do
  @moduledoc """
  Raw spectrum sweeps captured by FieldSurvey Sidekick SDR devices.
  """
  use Ash.Resource,
    domain: ServiceRadar.Spatial,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("survey_spectrum_observations")
    repo(ServiceRadar.Repo)
  end

  actions do
    defaults([:read, :destroy])

    action :bulk_insert, :boolean do
      argument(:session_id, :string, allow_nil?: false)
      argument(:observations, {:array, :map}, allow_nil?: false)

      run(ServiceRadar.Spatial.Actions.BulkInsertSpectrumObservations)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:session_id, :string, allow_nil?: false)
    attribute(:sidekick_id, :string, allow_nil?: false)
    attribute(:sdr_id, :string, allow_nil?: false)
    attribute(:device_kind, :string, allow_nil?: false)
    attribute(:serial_number, :string)
    attribute(:sweep_id, :integer, allow_nil?: false)

    attribute(:started_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:started_at_unix_nanos, :integer, allow_nil?: false)
    attribute(:captured_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:captured_at_unix_nanos, :integer, allow_nil?: false)

    attribute(:start_frequency_hz, :integer, allow_nil?: false)
    attribute(:stop_frequency_hz, :integer, allow_nil?: false)
    attribute(:bin_width_hz, :float, allow_nil?: false)
    attribute(:sample_count, :integer, allow_nil?: false)
    attribute(:power_bins_dbm, {:array, :float}, allow_nil?: false)
    attribute(:inserted_at, :utc_datetime_usec, allow_nil?: false)
  end
end
