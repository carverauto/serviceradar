defmodule ServiceRadar.Plugins.AddonAssignment do
  @moduledoc """
  Assignment of an approved native add-on (feature set) package to an agent.

  An operator-selected add-on for an agent. The AgentConfigGenerator compiles
  enabled assignments whose package is approved into the `addons` section of the
  agent configuration, which the agent supervises as go-plugin subprocesses.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Plugins.Changes.SetAssignmentAddonId
  alias ServiceRadar.Plugins.Validations.AddonPackageApproved
  alias ServiceRadar.Plugins.Validations.NoDuplicateEnabledAddonAssignment

  @mutable_fields [
    :addon_package_id,
    :source,
    :source_key,
    :enabled,
    :params,
    :args
  ]

  @create_fields [:agent_uid, :addon_package_id | @mutable_fields]

  postgres do
    table "addon_assignments"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :addon_package, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    read :by_package do
      argument :addon_package_id, :uuid, allow_nil?: false
      filter expr(addon_package_id == ^arg(:addon_package_id) and enabled == true)
    end

    read :by_agent do
      argument :agent_uid, :string, allow_nil?: false
      filter expr(agent_uid == ^arg(:agent_uid))
    end

    create :create do
      accept @create_fields

      change SetAssignmentAddonId
      validate AddonPackageApproved
      validate NoDuplicateEnabledAddonAssignment
    end

    update :update do
      accept @mutable_fields

      change SetAssignmentAddonId
      validate AddonPackageApproved
      validate NoDuplicateEnabledAddonAssignment
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

    attribute :addon_id, :string do
      allow_nil? false
      public? true

      description "Denormalized add-on identifier used to enforce one enabled assignment per agent/add-on."
    end

    attribute :addon_package_id, :uuid do
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

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :params, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :args, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :addon_package, ServiceRadar.Plugins.AddonPackage do
      allow_nil? false
      public? true
      destination_attribute :id
      source_attribute :addon_package_id
      define_attribute? false
    end
  end

  identities do
    identity :unique_source_key, [:source, :source_key]
  end
end
