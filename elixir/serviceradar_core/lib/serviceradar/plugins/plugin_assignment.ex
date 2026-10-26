defmodule ServiceRadar.Plugins.PluginAssignment do
  @moduledoc """
  Assignment of an approved plugin package to an agent.

  `plugin_package_id` is the assignment's stable package: the one its owner (an
  operator, a target policy, a credential rule) chose, and the only package
  owners and reconcilers write. While a Wasm plugin rollout proves a candidate on
  the assignment, `rollout_plugin_package_id` overrides it. The package an agent
  runs is the effective package, `COALESCE(rollout_plugin_package_id,
  plugin_package_id)` (`effective_package_id/1`), and every reader that asks what
  an assignment runs reads that, not the stable package.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Plugins.Changes.ApplyConfigDefaults
  alias ServiceRadar.Plugins.Changes.ApplyPluginUpdatePolicy
  alias ServiceRadar.Plugins.Changes.BindAssignmentPartition
  alias ServiceRadar.Plugins.Changes.ClearRetractionOnEnable
  alias ServiceRadar.Plugins.Changes.RejectLegacyUnboundAssignmentMutation
  alias ServiceRadar.Plugins.Changes.RejectPolicyOwnedAssignmentDestroy
  alias ServiceRadar.Plugins.Changes.ReleaseRolloutOverride
  alias ServiceRadar.Plugins.Changes.SetAssignmentPluginId
  alias ServiceRadar.Plugins.PluginPackage
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
    :resources_override,
    :update_policy,
    :update_policy_source
  ]

  @create_fields [:agent_uid, :plugin_package_id | @mutable_fields]

  @rollout_override_fields [:rollout_plugin_package_id, :rollout_id, :rollout_started_at]

  postgres do
    table "plugin_assignments"
    repo ServiceRadar.Repo
    schema "platform"

    check_constraints do
      check_constraint :rollout_id, "plugin_assignments_rollout_override_check",
        message: "rollout package, rollout and start time are set or cleared together"
    end
  end

  actions do
    defaults [:read]

    # Enabled assignments whose effective package is the given one: a rollout
    # candidate's assignments are found by the candidate, not by the stable
    # package they will return to.
    read :by_package do
      argument :plugin_package_id, :uuid, allow_nil?: false

      filter expr(
               enabled == true and
                 (rollout_plugin_package_id == ^arg(:plugin_package_id) or
                    (is_nil(rollout_plugin_package_id) and
                       plugin_package_id == ^arg(:plugin_package_id)))
             )
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
      change ApplyPluginUpdatePolicy
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
      change ApplyPluginUpdatePolicy
      change ClearRetractionOnEnable
      change ReleaseRolloutOverride
      validate PackageApproved
      validate NoDuplicateEnabledAssignment
      validate AssignmentParams
    end

    # Disables an assignment because its owner no longer covers it, and records
    # why and on whose action. It deliberately skips the package and parameter
    # validations of `:update`: a retraction must succeed even when the package
    # has since been revoked or the stored params no longer validate. See
    # ServiceRadar.Plugins.OwnedAssignmentRetraction.
    update :retract do
      # ReleaseRolloutOverride reads the stored override and rollout holds.
      require_atomic? false
      accept []

      argument :disabled_reason, :atom do
        allow_nil? false

        constraints one_of: [
                      :owner_disabled,
                      :owner_deleted,
                      :owner_scope_narrowed,
                      :orphaned_owner_cleanup
                    ]
      end

      argument :disabled_by, :string, allow_nil?: true

      change set_attribute(:enabled, false)
      change set_attribute(:disabled_reason, arg(:disabled_reason))
      change set_attribute(:disabled_by, arg(:disabled_by))
      change set_attribute(:disabled_at, &DateTime.utc_now/0)
      change ReleaseRolloutOverride
    end

    destroy :destroy do
      require_atomic? false
      change RejectLegacyUnboundAssignmentMutation
      change RejectPolicyOwnedAssignmentDestroy
    end

    # A rollout's per-target override. It changes only the override columns, so
    # the stable plugin_package_id that owners and reconcilers write is never
    # touched while a candidate is being proven.
    update :apply_rollout_override do
      require_atomic? false
      accept @rollout_override_fields
    end

    update :clear_rollout_override do
      require_atomic? false
      accept @rollout_override_fields
    end

    # A completed Wasm plugin rollout moves the stable package to its candidate
    # and drops the override in one write, so delivery never falls back to the
    # previous package in between. It is the rollout's write, not an operator's
    # version choice, so it leaves the update policy alone.
    update :promote_rollout do
      require_atomic? false
      accept [:plugin_package_id | @rollout_override_fields]

      change SetAssignmentPluginId
      validate PackageApproved
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

    attribute :partition_id, :string do
      allow_nil? false
      public? true
      description "Immutable mTLS-derived partition paired with agent_uid"
    end

    attribute :plugin_id, :string do
      allow_nil? false
      public? true

      description "Denormalized plugin identifier. Enabled uniqueness is per owner; see AssignmentOwner."
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

    attribute :update_policy, :atom do
      allow_nil? false
      public? true
      default :pinned
      constraints one_of: [:track_latest_approved, :pinned]

      description """
      Whether a manual assignment follows the latest approved package of its
      plugin or keeps its selected package. Policy-materialized rows follow
      their owner instead; see ServiceRadar.Plugins.PluginUpdatePolicy.
      """
    end

    attribute :update_policy_source, :atom do
      allow_nil? false
      public? true
      default :operator
      constraints one_of: [:migration_default, :operator]
      description "Who chose update_policy; only migration_default rows are backfilled."
    end

    attribute :disabled_reason, :atom do
      allow_nil? true
      public? true

      constraints one_of: [
                    :owner_disabled,
                    :owner_deleted,
                    :owner_scope_narrowed,
                    :orphaned_owner_cleanup
                  ]

      description "Why the assignment was retracted; cleared when it is enabled again."
    end

    attribute :disabled_by, :string do
      allow_nil? true
      public? true
      description "Actor whose action retracted the assignment."
    end

    attribute :disabled_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    # The candidate package a Wasm plugin rollout is proving on this row. The
    # three are set or cleared together (plugin_assignments_rollout_override_check).
    attribute :rollout_plugin_package_id, :uuid, public?: true
    attribute :rollout_id, :uuid, public?: true
    attribute :rollout_started_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :plugin_package, PluginPackage do
      allow_nil? false
      public? true
      destination_attribute :id
      source_attribute :plugin_package_id
      define_attribute? false
    end

    belongs_to :rollout_plugin_package, PluginPackage do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :rollout_plugin_package_id
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
    identity :unique_source_key, [:partition_id, :source, :source_key]
  end

  @doc """
  The id of the package an agent runs for `assignment`: the rollout candidate
  while a rollout holds the assignment, otherwise the stable package.

  Accepts any map with `plugin_package_id`; one without
  `rollout_plugin_package_id` has no override.
  """
  @spec effective_package_id(map()) :: Ecto.UUID.t() | nil
  def effective_package_id(%{rollout_plugin_package_id: package_id}) when not is_nil(package_id),
    do: package_id

  def effective_package_id(%{plugin_package_id: package_id}), do: package_id

  @doc """
  Puts the effective package in `plugin_package`, for readers that load the
  `plugin_package` and `rollout_plugin_package` relationships and then work
  from `plugin_package`. Without an override the assignment is returned as it
  is.
  """
  @spec put_effective_package(map()) :: map()
  def put_effective_package(%{rollout_plugin_package_id: nil} = assignment), do: assignment

  def put_effective_package(%{rollout_plugin_package: candidate} = assignment),
    do: %{assignment | plugin_package: candidate}
end
