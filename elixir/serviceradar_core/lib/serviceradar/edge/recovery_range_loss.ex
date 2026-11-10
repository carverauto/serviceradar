defmodule ServiceRadar.Edge.RecoveryRangeLoss do
  @moduledoc "Historical produced-range partial coverage, independent of mutable execution and slot lifecycle."
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_range_losses"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :record do
      accept [:span_id, :mapping_key, :mapping_value]
      upsert? true
      upsert_identity :produced_range
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
    attribute :mapping_key, :map, allow_nil?: false
    attribute :mapping_value, :map, allow_nil?: false

    attribute :coverage, :atom,
      allow_nil?: false,
      default: :partial,
      constraints: [one_of: [:partial]]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :span, ServiceRadar.Edge.RecoveryLossSpan, allow_nil?: false
  end

  identities do
    identity :produced_range, [:span_id]
  end
end
