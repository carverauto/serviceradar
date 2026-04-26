defmodule ServiceRadar.Spatial.SurveyPoseSample do
  @moduledoc """
  iOS ARKit/LiDAR pose samples used to fuse FieldSurvey RF observations.
  """
  use Ash.Resource,
    domain: ServiceRadar.Spatial,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("survey_pose_samples")
    repo(ServiceRadar.Repo)
  end

  actions do
    defaults([:read, :destroy])

    action :bulk_insert, :boolean do
      argument(:session_id, :string, allow_nil?: false)
      argument(:samples, {:array, :map}, allow_nil?: false)

      run(ServiceRadar.Spatial.Actions.BulkInsertPoseSamples)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:session_id, :string, allow_nil?: false)
    attribute(:scanner_device_id, :string, allow_nil?: false)

    attribute(:captured_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:captured_at_unix_nanos, :integer, allow_nil?: false)
    attribute(:captured_at_monotonic_nanos, :integer)

    attribute(:x, :float, allow_nil?: false)
    attribute(:y, :float, allow_nil?: false)
    attribute(:z, :float, allow_nil?: false)
    attribute(:qx, :float, allow_nil?: false)
    attribute(:qy, :float, allow_nil?: false)
    attribute(:qz, :float, allow_nil?: false)
    attribute(:qw, :float, allow_nil?: false)

    attribute(:latitude, :float)
    attribute(:longitude, :float)
    attribute(:altitude, :float)
    attribute(:accuracy_m, :float)
    attribute(:tracking_quality, :string)
    attribute(:inserted_at, :utc_datetime_usec, allow_nil?: false)
  end
end
