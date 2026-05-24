defmodule ServiceRadar.Dashboards.DashboardUserPreference do
  @moduledoc """
  Per-user dashboard discovery preferences.

  Preferences can point at authored dashboards or enabled dashboard package
  routes. This keeps favorites and the default dashboard independent from any
  single dashboard implementation.
  """

  use Ash.Resource,
    domain: ServiceRadar.Dashboards,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @fields [:user_id, :target_type, :target_id, :favorite, :is_default, :metadata]

  postgres do
    table "dashboard_user_preferences"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false

    references do
      reference :user, on_delete: :delete
    end
  end

  code_interface do
    define :list, action: :read
    define :for_user, action: :for_user, args: [:user_id]
    define :upsert_preference, action: :upsert
    define :clear_default, action: :clear_default
  end

  actions do
    defaults [:read, :destroy]

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    create :upsert do
      accept @fields
      upsert? true
      upsert_identity :unique_user_target
      upsert_fields [:favorite, :is_default, :metadata, :updated_at]
    end

    update :update do
      accept [:favorite, :is_default, :metadata]
    end

    update :clear_default do
      accept []
      change set_attribute(:is_default, false)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:create) do
      authorize_if ServiceRadar.Dashboards.Checks.CreatingOwnDashboardPreference
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :target_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:authored, :package]
    end

    attribute :target_id, :string do
      allow_nil? false
      public? true
      description "Authored dashboard UUID or dashboard package route slug."
    end

    attribute :favorite, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :is_default, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, ServiceRadar.Identity.User do
      allow_nil? false
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :user_id
    end
  end

  identities do
    identity :unique_user_target, [:user_id, :target_type, :target_id]
  end
end
