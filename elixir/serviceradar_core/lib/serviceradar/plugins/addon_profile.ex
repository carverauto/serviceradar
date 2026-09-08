defmodule ServiceRadar.Plugins.AddonProfile do
  @moduledoc """
  Query-driven native add-on profile.

  Profiles let operators assign native add-ons to agents using SRQL over the
  inventory, matching the targeting model used by plugin target policies.
  Reconciliation materializes profile-owned `AddonAssignment` rows by source key.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Plugins.AddonProfileOps
  alias ServiceRadar.Plugins.Changes.ApplyAddonConfigDefaults
  alias ServiceRadar.Plugins.Changes.ApplyAddonUpdatePolicyDefaults
  alias ServiceRadar.Plugins.Changes.NormalizeAddonProfileTargetQuery
  alias ServiceRadar.Plugins.Changes.SetAssignmentAddonId
  alias ServiceRadar.Plugins.Validations.AddonAssignmentParams
  alias ServiceRadar.Plugins.Validations.AddonPackageApproved
  alias ServiceRadar.Plugins.Validations.AddonProfileTargetQuery
  alias ServiceRadar.Plugins.Validations.SingleEnabledAddonProfile

  @mutable_fields [
    :name,
    :description,
    :addon_package_id,
    :target_query,
    :params,
    :args,
    :priority,
    :max_targets,
    :metadata,
    :enabled,
    :update_policy,
    :explicit_version_pin,
    :release_channel,
    :capability_ceiling,
    :rollout_policy
  ]

  postgres do
    table "addon_profiles"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      # Race backstop for Validations.SingleEnabledAddonProfile: the
      # validation reads-then-writes, so two concurrent enables can both pass
      # it. Predicate must stay in sync with @exclusive_addon_ids there.
      index [:addon_id],
        name: "addon_profiles_single_enabled_anomaly_index",
        unique: true,
        where: "enabled AND addon_id = 'anomaly'",
        message: "only one enabled add-on profile is allowed for the anomaly add-on"
    end

    references do
      reference :addon_package, on_delete: :delete
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_enabled, action: :enabled
    define :preview, action: :preview
    define :reconcile_now, action: :reconcile_now
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    read :enabled do
      filter expr(enabled == true)
    end

    create :create do
      accept @mutable_fields

      change SetAssignmentAddonId
      change ApplyAddonConfigDefaults
      change ApplyAddonUpdatePolicyDefaults
      change NormalizeAddonProfileTargetQuery
      validate AddonPackageApproved
      validate AddonAssignmentParams
      validate AddonProfileTargetQuery
      validate SingleEnabledAddonProfile
    end

    update :update do
      # SingleEnabledAddonProfile requires a cross-row read ({:not_atomic, ..}),
      # so updates must fall back to the non-atomic path (where validate/3
      # runs) instead of erroring MustBeAtomic.
      require_atomic? false

      accept @mutable_fields

      change SetAssignmentAddonId
      change ApplyAddonConfigDefaults
      change ApplyAddonUpdatePolicyDefaults
      change NormalizeAddonProfileTargetQuery
      validate AddonPackageApproved
      validate AddonAssignmentParams
      validate AddonProfileTargetQuery
      validate SingleEnabledAddonProfile
    end

    update :record_reconcile_result do
      description "Persist reconciliation outcome without revalidating desired add-on state."
      accept [:last_reconciled_at, :last_reconcile_summary]
    end

    update :restore_managed_update_policy do
      description "Restore a non-explicit trusted first-party source to managed updates."
      require_atomic? false
      accept [:update_policy, :capability_ceiling]
    end

    update :promote_rollout do
      description "Promote a successfully health-gated rollout into stable profile state."
      require_atomic? false
      accept [:addon_package_id]

      change SetAssignmentAddonId
      change ApplyAddonConfigDefaults
      validate AddonPackageApproved
      validate AddonAssignmentParams
      validate SingleEnabledAddonProfile
    end

    action :preview do
      argument :id, :uuid, allow_nil?: false
      argument :sample_limit, :integer, allow_nil?: true, default: 10
      returns :map

      run fn input, context ->
        AddonProfileOps.preview_by_id(input.arguments.id,
          sample_limit: input.arguments.sample_limit,
          actor: action_actor(context)
        )
      end
    end

    action :reconcile_now do
      argument :id, :uuid, allow_nil?: false
      returns :map

      run fn input, context ->
        AddonProfileOps.reconcile_by_id(input.arguments.id, actor: action_actor(context))
      end
    end
  end

  policies do
    import ServiceRadar.Plugins.Policies

    manage_actions([
      :create,
      :update,
      :destroy,
      :preview,
      :reconcile_now,
      :promote_rollout,
      :record_reconcile_result
    ])
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :addon_id, :string do
      allow_nil? false
      public? true
      description "Denormalized add-on identifier from the selected package."
    end

    attribute :addon_package_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :target_query, :string do
      allow_nil? false
      public? true

      description "SRQL query that selects target agents. Must use in:agents; extra filters are allowed."
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

    attribute :priority, :integer do
      allow_nil? false
      public? true
      default 100
      constraints min: 0
    end

    attribute :max_targets, :integer do
      allow_nil? false
      public? true
      default 10_000
      constraints min: 1, max: 1_000_000
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :last_reconciled_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_reconcile_summary, :map do
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

    has_many :assignments, ServiceRadar.Plugins.AddonAssignment do
      public? true
      destination_attribute :addon_profile_id
    end
  end

  defp action_actor(%{actor: actor}), do: actor
  defp action_actor(_context), do: nil
end
