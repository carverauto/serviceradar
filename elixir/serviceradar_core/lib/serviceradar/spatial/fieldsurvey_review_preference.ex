defmodule ServiceRadar.Spatial.FieldSurveyReviewPreference do
  @moduledoc """
  Per-user FieldSurvey review favorites and default session selection.
  """
  use Ash.Resource,
    domain: ServiceRadar.Spatial,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "fieldsurvey_review_preferences"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  code_interface do
    define :for_user_sessions, action: :for_user_sessions, args: [:user_id, :session_ids]
    define :default_for_user, action: :default_for_user, args: [:user_id]
    define :upsert, action: :upsert
  end

  actions do
    defaults [:read, :destroy]

    read :for_user_sessions do
      argument :user_id, :string, allow_nil?: false
      argument :session_ids, {:array, :string}, allow_nil?: false

      filter expr(user_id == ^arg(:user_id) and session_id in ^arg(:session_ids))
    end

    read :default_for_user do
      argument :user_id, :string, allow_nil?: false

      filter expr(user_id == ^arg(:user_id) and default_view == true)
      prepare fn query, _ -> Ash.Query.sort(query, updated_at: :desc) end
    end

    create :upsert do
      primary? true
      upsert? true
      upsert_identity :unique_user_session

      accept [:user_id, :session_id, :favorite, :default_view, :metadata]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :user_id, :string do
      allow_nil? false
      public? true
    end

    attribute :session_id, :string do
      allow_nil? false
      public? true
    end

    attribute :favorite, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :default_view, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_user_session, [:user_id, :session_id]
  end
end
