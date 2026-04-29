defmodule ServiceRadar.Spatial.SurveySessionMetadata do
  @moduledoc """
  Site/building/floor attribution for FieldSurvey sessions.
  """
  use Ash.Resource,
    domain: ServiceRadar.Spatial,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "survey_session_metadata"
    repo ServiceRadar.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :session_id,
        :user_id,
        :site_id,
        :site_name,
        :building_id,
        :building_name,
        :floor_id,
        :floor_name,
        :floor_index,
        :tags,
        :metadata
      ]
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_session

      accept [
        :session_id,
        :user_id,
        :site_id,
        :site_name,
        :building_id,
        :building_name,
        :floor_id,
        :floor_name,
        :floor_index,
        :tags,
        :metadata
      ]
    end
  end

  attributes do
    attribute :session_id, :string, primary_key?: true, allow_nil?: false
    attribute :user_id, :string, allow_nil?: false
    attribute :site_id, :string
    attribute :site_name, :string
    attribute :building_id, :string
    attribute :building_name, :string
    attribute :floor_id, :string
    attribute :floor_name, :string
    attribute :floor_index, :integer
    attribute :tags, {:array, :string}, allow_nil?: false, default: []
    attribute :metadata, :map, allow_nil?: false, default: %{}

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_session, [:session_id]
  end
end
