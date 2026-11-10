defmodule ServiceRadar.Edge.RecoveryAssignmentKey do
  @moduledoc "Serializes the candidate set and selected projection of a historical mapping."
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_assignment_keys"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :ensure do
      accept [:mapping_key]
      upsert? true
      upsert_identity :full_key
      upsert_fields []
    end

    update :project do
      accept [:generation, :selected_issuance_id, :selection_generation, :resolver_epoch]
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
    attribute :generation, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :selection_generation, :integer, constraints: [min: 1]
    attribute :resolver_epoch, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    timestamps()
  end

  relationships do
    belongs_to :selected_issuance, ServiceRadar.Edge.RecoveryAssignmentIssuance
  end

  identities do
    identity :full_key, [:mapping_key]
  end
end
