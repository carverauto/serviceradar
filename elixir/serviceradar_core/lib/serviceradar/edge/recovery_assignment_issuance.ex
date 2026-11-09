defmodule ServiceRadar.Edge.RecoveryAssignmentIssuance do
  @moduledoc """
  Original pre-accept issuance evidence. There is no lifecycle foreign key or deletion action.
  It survives loss of the candidate/projection and is the only permitted source of repair.
  """
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_assignment_issuances"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :record do
      accept [:mapping_key, :mapping_value, :evidence, :evidence_sha256]
      upsert? true
      upsert_identity :original_value
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

    attribute :evidence, :string,
      allow_nil?: false,
      constraints: [max_length: 32_768, trim?: false]

    attribute :evidence_sha256, :binary, allow_nil?: false
    create_timestamp :inserted_at
  end

  identities do
    identity :original_value, [:mapping_key, :mapping_value]
  end
end
