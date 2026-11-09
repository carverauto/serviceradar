defmodule ServiceRadar.Edge.RecoveryAssignmentCandidate do
  @moduledoc "Append-only candidate membership; selecting a value never removes its competitors."
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_assignment_candidates"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :record do
      accept [:key_id, :issuance_id]
      upsert? true
      upsert_identity :membership
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
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :key, ServiceRadar.Edge.RecoveryAssignmentKey, allow_nil?: false
    belongs_to :issuance, ServiceRadar.Edge.RecoveryAssignmentIssuance, allow_nil?: false
  end

  identities do
    identity :membership, [:key_id, :issuance_id]
  end
end
