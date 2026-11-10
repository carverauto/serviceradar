defmodule ServiceRadar.Edge.RecoveryLossSpan do
  @moduledoc "Immutable span identity/body with its consumer-effect projection; blocked spans are quarantined here."
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_loss_spans"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :network_scope_id,
        :agent_id,
        :recovery_id,
        :page_index,
        :span_index,
        :prior_spool_id,
        :span
      ]

      upsert? true
      upsert_identity :span_identity
      upsert_fields []
    end

    update :apply do
      accept [:state, :outcome, :mapping_value]
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
    attribute :page_index, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :span_index, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :prior_spool_id, :uuid, allow_nil?: false
    attribute :span, :binary, allow_nil?: false

    attribute :state, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :blocked, :applied]]

    attribute :outcome, :atom,
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
    timestamps()
  end

  identities do
    identity :span_identity, [
      :network_scope_id,
      :agent_id,
      :recovery_id,
      :page_index,
      :span_index
    ]
  end
end
