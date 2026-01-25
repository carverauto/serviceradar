defmodule ServiceRadar.Plugins.PluginAssignment do
  @moduledoc """
  Assignment of an approved plugin package to an agent.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "plugin_assignments"
    repo ServiceRadar.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :by_agent do
      argument :agent_uid, :string, allow_nil?: false
      filter expr(agent_uid == ^arg(:agent_uid))
    end

    create :create do
      accept [
        :agent_uid,
        :plugin_package_id,
        :enabled,
        :interval_seconds,
        :timeout_seconds,
        :params,
        :permissions_override,
        :resources_override
      ]

      change ServiceRadar.Plugins.Changes.ApplyConfigDefaults
      validate ServiceRadar.Plugins.Validations.PackageApproved
      validate ServiceRadar.Plugins.Validations.AssignmentParams
    end

    update :update do
      accept [
        :enabled,
        :interval_seconds,
        :timeout_seconds,
        :params,
        :permissions_override,
        :resources_override
      ]

      change ServiceRadar.Plugins.Changes.ApplyConfigDefaults
      validate ServiceRadar.Plugins.Validations.AssignmentParams
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :agent_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :plugin_package_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :interval_seconds, :integer do
      allow_nil? false
      public? true
      default 60
    end

    attribute :timeout_seconds, :integer do
      allow_nil? false
      public? true
      default 10
    end

    attribute :params, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :permissions_override, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :resources_override, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :plugin_package, ServiceRadar.Plugins.PluginPackage do
      allow_nil? false
      public? true
      destination_attribute :id
      source_attribute :plugin_package_id
      define_attribute? false
    end
  end

  identities do
    identity :unique_agent_package, [:agent_uid, :plugin_package_id]
  end
end
