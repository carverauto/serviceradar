defmodule ServiceRadar.Plugins.PluginAssignment do
  @moduledoc """
  Assignment of an approved plugin package to an agent.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Plugins.Changes.ApplyConfigDefaults
  alias ServiceRadar.Plugins.Changes.BindAssignmentPartition
  alias ServiceRadar.Plugins.Changes.RejectLegacyUnboundAssignmentMutation
  alias ServiceRadar.Plugins.Changes.SetAssignmentPluginId
  alias ServiceRadar.Plugins.Validations.AssignmentParams
  alias ServiceRadar.Plugins.Validations.NoDuplicateEnabledAssignment
  alias ServiceRadar.Plugins.Validations.PackageApproved

  @mutable_fields [
    :plugin_package_id,
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
    defaults [:read]

    read :by_package do
      argument :plugin_package_id, :uuid, allow_nil?: false
      filter expr(plugin_package_id == ^arg(:plugin_package_id) and enabled == true)
    end

    read :by_agent do
      argument :agent_uid, :string, allow_nil?: false
      argument :partition_id, :string, allow_nil?: false

      filter expr(agent_uid == ^arg(:agent_uid) and partition_id == ^arg(:partition_id))
    end

    read :by_edge_principal do
      argument :agent_uid, :string, allow_nil?: false
      argument :partition_id, :string, allow_nil?: false
      filter expr(agent_uid == ^arg(:agent_uid) and partition_id == ^arg(:partition_id))
    end

    # Fleet reconciliation intentionally enumerates every partition. The action
    # name makes that broad scope explicit; it must never be used as a single
    # assignment lookup.
    read :all_partitions_for_policy do
      argument :policy_id, :string, allow_nil?: false
      filter expr(source == :policy and policy_id == ^arg(:policy_id))
    end

    read :by_partition_source_key do
      argument :partition_id, :string, allow_nil?: false
      argument :source, :atom, allow_nil?: false
      argument :source_key, :string, allow_nil?: false
      get? true

      filter expr(
               partition_id == ^arg(:partition_id) and source == ^arg(:source) and
                 source_key == ^arg(:source_key)
             )
    end

    create :create do
      accept @create_fields

      change BindAssignmentPartition
      change SetAssignmentPluginId
      change ApplyConfigDefaults
      validate PackageApproved
      validate NoDuplicateEnabledAssignment
      validate ServiceRadar.Plugins.Validations.NoShadowedManualAssignment
      validate AssignmentParams
    end

    update :update do
      # Legacy-unbound mutation is a runtime guard because the row's current
      # persisted state is part of the authorization boundary.
      require_atomic? false
      accept @mutable_fields

      change RejectLegacyUnboundAssignmentMutation
      change SetAssignmentPluginId
      change ApplyConfigDefaults
      validate PackageApproved
      validate NoDuplicateEnabledAssignment
      validate AssignmentParams
    end

    destroy :destroy do
      require_atomic? false
      change RejectLegacyUnboundAssignmentMutation
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

    attribute :partition_id, :string do
      allow_nil? false
      public? true
      description "Immutable mTLS-derived partition paired with agent_uid"
    end

    attribute :plugin_id, :string do
      allow_nil? false
      public? true

      description "Denormalized plugin identifier used to enforce one enabled assignment per agent/plugin."
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
    identity :unique_source_key, [:partition_id, :source, :source_key]
  end
end
