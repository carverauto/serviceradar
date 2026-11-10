defmodule ServiceRadar.Edge.RecoveryAssignmentResolution do
  @moduledoc "Append-only resolver decisions, including rejected stale and contradictory attempts."
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_assignment_resolutions"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:key_id, :candidate_generation]
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:key_id, :issuance_id, :resolver_epoch, :candidate_generation, :outcome]
      upsert? true
      upsert_identity :attempt
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
    attribute :resolver_epoch, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :candidate_generation, :integer, allow_nil?: false, constraints: [min: 0]

    attribute :outcome, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :selected,
          :stale_resolver,
          :future_resolver,
          :changed_candidates,
          :unknown_candidate,
          :selection_conflict,
          :corrupt,
          :conflicting
        ]
      ]

    create_timestamp :inserted_at
  end

  attributes do
    attribute :issuance_id, :uuid, allow_nil?: false
  end

  relationships do
    belongs_to :key, ServiceRadar.Edge.RecoveryAssignmentKey, allow_nil?: false
    # A rejected attempt may name a nonexistent candidate; retain its exact operand.
  end

  identities do
    identity :attempt, [:key_id, :resolver_epoch, :candidate_generation, :issuance_id, :outcome]
  end
end
