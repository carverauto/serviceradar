defmodule ServiceRadar.Plugins.AddonRollout do
  @moduledoc """
  Durable, health-gated promotion of one package for one authoritative source.

  `artifact_kind` says which artifact family the rollout moves, and with it
  which package pair is set: a `:native_addon` rollout records
  `previous_package_id`/`candidate_package_id` (add-on packages) for a direct
  assignment or profile; a `:wasm_plugin` rollout records
  `previous_plugin_package_id`/`candidate_plugin_package_id` (plugin packages)
  for a manual assignment, target policy or credential rule, with the rule's
  purpose in `source_key`. The `addon_rollouts_artifact_kind_check` constraint
  enforces the pairing. Readers that act on add-on rollouts filter
  `artifact_kind == :native_addon`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.PluginPackage

  @create_fields [
    :artifact_kind,
    :addon_id,
    :source_type,
    :source_id,
    :source_key,
    :previous_package_id,
    :candidate_package_id,
    :previous_plugin_package_id,
    :candidate_plugin_package_id,
    :trigger,
    :state,
    :policy,
    :target_snapshot,
    :blocked_reason,
    :error,
    :started_at,
    :completed_at
  ]

  @update_fields [
    :state,
    :target_snapshot,
    :blocked_reason,
    :error,
    :started_at,
    :paused_at,
    :completed_at,
    :canceled_at
  ]

  postgres do
    table "addon_rollouts"
    repo ServiceRadar.Repo
    schema "platform"

    check_constraints do
      check_constraint :artifact_kind, "addon_rollouts_artifact_kind_check",
        message: "must match the package pair and source type of its artifact kind"
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept @create_fields
    end

    update :update do
      require_atomic? false
      accept @update_fields
    end
  end

  policies do
    import ServiceRadar.Plugins.Policies

    manage_action_types()
  end

  attributes do
    uuid_primary_key :id

    attribute :artifact_kind, :atom do
      allow_nil? false
      public? true
      default :native_addon
      constraints one_of: [:native_addon, :wasm_plugin]
    end

    # The artifact identifier: the add-on id, or the plugin id of a Wasm rollout.
    attribute :addon_id, :string, allow_nil?: false, public?: true

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      # :assignment and :profile are add-on sources; :assignment,
      # :target_policy and :credential_rule are Wasm plugin owners.
      constraints one_of: [:assignment, :profile, :target_policy, :credential_rule]
    end

    attribute :source_id, :uuid, allow_nil?: false, public?: true
    attribute :source_key, :string, public?: true
    attribute :previous_package_id, :uuid, public?: true
    attribute :candidate_package_id, :uuid, public?: true
    attribute :previous_plugin_package_id, :uuid, public?: true
    attribute :candidate_plugin_package_id, :uuid, public?: true

    attribute :trigger, :atom do
      allow_nil? false
      public? true
      default :track_latest
      constraints one_of: [:track_latest, :manual, :retry]
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :pending

      constraints one_of: [
                    :pending,
                    :running,
                    :paused,
                    :rolling_back,
                    :completed,
                    :failed,
                    :canceled,
                    :rolled_back,
                    # The fleet reached the candidate version by some other
                    # route -- a later rollout, a direct assignment, a
                    # reinstall -- so there is nothing left for this rollout to
                    # do. Terminal, and distinct from :completed because this
                    # rollout did not perform the convergence.
                    :superseded
                  ]
    end

    attribute :policy, :map, allow_nil?: false, public?: true, default: %{}
    attribute :target_snapshot, :map, allow_nil?: false, public?: true, default: %{}
    attribute :blocked_reason, :string, public?: true
    attribute :error, :string, public?: true
    attribute :started_at, :utc_datetime_usec, public?: true
    attribute :paused_at, :utc_datetime_usec, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true
    attribute :canceled_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :previous_package, AddonPackage do
      source_attribute :previous_package_id
      destination_attribute :id
      define_attribute? false
      allow_nil? true
      public? true
    end

    belongs_to :candidate_package, AddonPackage do
      source_attribute :candidate_package_id
      destination_attribute :id
      define_attribute? false
      allow_nil? true
      public? true
    end

    belongs_to :previous_plugin_package, PluginPackage do
      source_attribute :previous_plugin_package_id
      destination_attribute :id
      define_attribute? false
      allow_nil? true
      public? true
    end

    belongs_to :candidate_plugin_package, PluginPackage do
      source_attribute :candidate_plugin_package_id
      destination_attribute :id
      define_attribute? false
      allow_nil? true
      public? true
    end

    has_many :targets, ServiceRadar.Plugins.AddonRolloutTarget do
      destination_attribute :rollout_id
      public? true
    end
  end
end
