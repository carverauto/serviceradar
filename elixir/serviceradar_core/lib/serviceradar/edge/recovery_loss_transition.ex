defmodule ServiceRadar.Edge.RecoveryLossTransition do
  @moduledoc "Append-only first occurrence of each meaningful lookup outcome; repeated deliveries add no audit rows."
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_loss_transitions"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :record do
      accept [:span_id, :outcome, :mapping_value]
      upsert? true
      upsert_identity :first_outcome
      upsert_fields []
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :outcome, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :found,
          :not_scheduled,
          :temporarily_unavailable,
          :missing,
          :corrupt,
          :conflicting,
          :unattributable,
          :body_conflict,
          :range_conflict
        ]
      ]

    attribute :mapping_value, :map
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :span, ServiceRadar.Edge.RecoveryLossSpan, allow_nil?: false
  end

  identities do
    identity :first_outcome, [:span_id, :outcome]
  end
end
