defmodule ServiceRadar.Edge.RecoveryRetryIntent do
  @moduledoc "Stable semantic work queued by recovery, consumed by the existing desired-work lease reconciler."
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_retry_intents"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:scheduler, :disposition, :inserted_at],
        name: "edge_recovery_retry_intents_pending_index"
    end
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [:network_scope_id, :agent_id, :recovery_id, :intent_key, :mapping_value, :scheduler]
      upsert? true
      upsert_identity :semantic_work
      upsert_fields []
    end

    update :reconcile do
      accept [:disposition]
      change set_attribute(:reconciled_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :network_scope_id, :uuid, allow_nil?: false
    attribute :agent_id, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 256]
    attribute :recovery_id, :uuid, allow_nil?: false
    attribute :intent_key, :map, allow_nil?: false
    attribute :mapping_value, :map
    attribute :scheduler, :atom, allow_nil?: false, constraints: [one_of: [:sweep, :unassigned]]

    attribute :disposition, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :reconciled, :obsolete]]

    attribute :reconciled_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end

  identities do
    identity :semantic_work, [:network_scope_id, :agent_id, :recovery_id, :intent_key]
  end
end
