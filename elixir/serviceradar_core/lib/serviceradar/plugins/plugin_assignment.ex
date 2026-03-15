defmodule ServiceRadar.Plugins.PluginAssignment do
  @moduledoc """
  Assignment of an approved plugin package to an agent.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Plugins.Changes.ApplyConfigDefaults
  alias ServiceRadar.Plugins.Validations.AssignmentParams

  @mutable_fields [
    :source,
    :source_key,
    :policy_id,
    :enabled,
    :interval_seconds,
    :timeout_seconds,
    :params,
    :permissions_override,
    :resources_override
  ]

  @create_fields [:agent_uid, :plugin_package_id | @mutable_fields]

  postgres do
    table "plugin_assignments"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    read :by_agent do
      argument :agent_uid, :string, allow_nil?: false
      filter expr(agent_uid == ^arg(:agent_uid))
    end

    read :by_policy do
      argument :policy_id, :string, allow_nil?: false
      filter expr(source == :policy and policy_id == ^arg(:policy_id))
    end

    read :by_source_key do
      argument :source, :atom, allow_nil?: false
      argument :source_key, :string, allow_nil?: false
      get? true
      filter expr(source == ^arg(:source) and source_key == ^arg(:source_key))
    end

    create :create do
      accept @create_fields

      change ApplyConfigDefaults
      validate ServiceRadar.Plugins.Validations.PackageApproved
      validate AssignmentParams
    end

    update :update do
      accept @mutable_fields

      change ApplyConfigDefaults
      validate AssignmentParams
    end
  end

  policies do
    import ServiceRadar.Plugins.Policies

    manage_action_types()
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

    attribute :source, :atom do
      allow_nil? false
      public? true
      default :manual
      constraints one_of: [:manual, :policy]
    end

    attribute :source_key, :string do
      allow_nil? true
      public? true
    end

    attribute :policy_id, :string do
      allow_nil? true
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
    identity :unique_source_key, [:source, :source_key]
  end
end
