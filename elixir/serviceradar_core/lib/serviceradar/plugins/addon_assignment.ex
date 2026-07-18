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

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.Changes.ApplyAddonConfigDefaults
  alias ServiceRadar.Plugins.Changes.ApplyAddonUpdatePolicyDefaults
  alias ServiceRadar.Plugins.Changes.SetAssignmentAddonId
  alias ServiceRadar.Plugins.Validations.AddonAssignmentParams
  alias ServiceRadar.Plugins.Validations.AddonPackageApproved
  alias ServiceRadar.Plugins.Validations.NoDuplicateEnabledAddonAssignment

  @mutable_fields [
    :addon_package_id,
    :source,
    :source_key,
    :addon_profile_id,
    :enabled,
    :params,
    :args,
    :profile_reconcile_status,
    :profile_reconcile_error,
    :profile_last_reconciled_at,
    :profile_metadata,
    :update_policy,
    :explicit_version_pin,
    :release_channel,
    :capability_ceiling,
    :rollout_policy
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

    read :by_profile do
      argument :addon_profile_id, :uuid, allow_nil?: false
      filter expr(source == :profile and addon_profile_id == ^arg(:addon_profile_id))
    end

    read :by_source_key do
      argument :source, :atom, allow_nil?: false
      argument :source_key, :string, allow_nil?: false
      get? true
      filter expr(source == ^arg(:source) and source_key == ^arg(:source_key))
    end

    create :create do
      accept @create_fields

      change SetAssignmentAddonId
      change ApplyAddonConfigDefaults
      change ApplyAddonUpdatePolicyDefaults
      validate AddonPackageApproved
      validate NoDuplicateEnabledAddonAssignment
      validate AddonAssignmentParams
    end

    update :update do
      accept @mutable_fields

      change SetAssignmentAddonId
      change ApplyAddonConfigDefaults
      change ApplyAddonUpdatePolicyDefaults
      validate AddonPackageApproved
      validate NoDuplicateEnabledAddonAssignment
      validate AddonAssignmentParams
    end

    update :apply_rollout_override do
      require_atomic? false
      accept [:rollout_package_id, :rollout_id, :rollout_started_at]
    end

    update :clear_rollout_override do
      require_atomic? false
      accept [:rollout_package_id, :rollout_id, :rollout_started_at]
    end

    update :promote_rollout do
      require_atomic? false
      accept [:addon_package_id, :rollout_package_id, :rollout_id, :rollout_started_at]

      change SetAssignmentAddonId
      change ApplyAddonConfigDefaults
      validate AddonPackageApproved
      validate AddonAssignmentParams
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
      constraints one_of: [:manual, :policy, :profile]
    end

    attribute :source_key, :string do
      allow_nil? true
      public? true
    end

    attribute :addon_profile_id, :uuid do
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

    attribute :profile_reconcile_status, :string do
      allow_nil? true
      public? true
    end

    attribute :profile_reconcile_error, :string do
      allow_nil? true
      public? true
    end

    attribute :profile_last_reconciled_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :profile_metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :update_policy, :atom do
      allow_nil? false
      public? true
      default :manual_pin
      constraints one_of: [:manual_pin, :track_latest_approved]
    end

    attribute :explicit_version_pin, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :release_channel, :string do
      allow_nil? false
      public? true
      default "stable"
    end

    attribute :capability_ceiling, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :rollout_policy, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :rollout_package_id, :uuid, public?: true
    attribute :rollout_id, :uuid, public?: true
    attribute :rollout_started_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :addon_package, AddonPackage do
      allow_nil? false
      public? true
      destination_attribute :id
      source_attribute :addon_package_id
      define_attribute? false
    end

    belongs_to :addon_profile, ServiceRadar.Plugins.AddonProfile do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :addon_profile_id
      define_attribute? false
    end

    belongs_to :rollout_package, AddonPackage do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :rollout_package_id
      define_attribute? false
    end

    belongs_to :rollout, ServiceRadar.Plugins.AddonRollout do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :rollout_id
      define_attribute? false
    end
  end

  identities do
    identity :unique_source_key, [:source, :source_key]
  end
end
