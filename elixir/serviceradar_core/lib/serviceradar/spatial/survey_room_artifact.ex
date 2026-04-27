defmodule ServiceRadar.Spatial.SurveyRoomArtifact do
  @moduledoc """
  Metadata for FieldSurvey room scan artifacts stored outside Postgres.
  """
  use Ash.Resource,
    domain: ServiceRadar.Spatial,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("survey_room_artifacts")
    repo(ServiceRadar.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :session_id,
        :user_id,
        :artifact_type,
        :content_type,
        :object_key,
        :byte_size,
        :sha256,
        :captured_at,
        :metadata,
        :uploaded_at
      ])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:session_id, :string, allow_nil?: false)
    attribute(:user_id, :string, allow_nil?: false)
    attribute(:artifact_type, :string, allow_nil?: false)
    attribute(:content_type, :string, allow_nil?: false)
    attribute(:object_key, :string, allow_nil?: false)
    attribute(:byte_size, :integer, allow_nil?: false)
    attribute(:sha256, :string, allow_nil?: false)
    attribute(:captured_at, :utc_datetime_usec)
    attribute(:metadata, :map, allow_nil?: false, default: %{})
    attribute(:uploaded_at, :utc_datetime_usec, allow_nil?: false)
  end
end
