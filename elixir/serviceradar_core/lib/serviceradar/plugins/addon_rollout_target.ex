defmodule ServiceRadar.Plugins.AddonRolloutTarget do
  @moduledoc """
  Snapshotted per-agent target and health evidence for a native add-on rollout.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @create_fields [
    :rollout_id,
    :assignment_id,
    :agent_uid,
    :addon_id,
    :source_type,
    :source_id,
    :previous_package_id,
    :candidate_package_id,
    :previous_params,
    :previous_args,
    :batch_index,
    :classification,
    :state,
    :reason_code
  ]

  @update_fields [
    :state,
    :classification,
    :reason_code,
    :error,
    :override_applied_at,
    :deadline_at,
    :healthy_since,
    :health_observed_at,
    :rollback_started_at,
    :completed_at,
    :rolled_back_at
  ]

  postgres do
    table "addon_rollout_targets"
    repo ServiceRadar.Repo
    schema "platform"
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
    attribute :rollout_id, :uuid, allow_nil?: false, public?: true
    attribute :assignment_id, :uuid, allow_nil?: false, public?: true
    attribute :agent_uid, :string, allow_nil?: false, public?: true
    attribute :addon_id, :string, allow_nil?: false, public?: true

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:assignment, :profile]
    end

    attribute :source_id, :uuid, allow_nil?: false, public?: true
    attribute :previous_package_id, :uuid, allow_nil?: false, public?: true
    attribute :candidate_package_id, :uuid, allow_nil?: false, public?: true
    attribute :previous_params, :map, allow_nil?: false, public?: true, default: %{}

    attribute :previous_args, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :batch_index, :integer, allow_nil?: false, public?: true

    attribute :classification, :atom do
      allow_nil? false
      public? true
      default :eligible
      constraints one_of: [:eligible, :unavailable, :incompatible, :overridden, :unresolved]
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :pending

      constraints one_of: [
                    :pending,
                    :waiting_health,
                    :healthy_soak,
                    :succeeded,
                    :promoted,
                    :failed,
                    :rollback_pending,
                    :rolled_back,
                    :excluded,
                    :canceled
                  ]
    end

    attribute :reason_code, :string, public?: true
    attribute :error, :string, public?: true
    attribute :override_applied_at, :utc_datetime_usec, public?: true
    attribute :deadline_at, :utc_datetime_usec, public?: true
    attribute :healthy_since, :utc_datetime_usec, public?: true
    attribute :health_observed_at, :utc_datetime_usec, public?: true
    attribute :rollback_started_at, :utc_datetime_usec, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true
    attribute :rolled_back_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :rollout, ServiceRadar.Plugins.AddonRollout do
      source_attribute :rollout_id
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end

    belongs_to :assignment, ServiceRadar.Plugins.AddonAssignment do
      source_attribute :assignment_id
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end
  end
end
