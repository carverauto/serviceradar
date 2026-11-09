defmodule ServiceRadar.Edge.RecoveryGenerationFence do
  @moduledoc "Fences only the affected prior generation; new generations and recovery/control remain able to progress."
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_generation_fences"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :fence do
      accept [:network_scope_id, :agent_id, :prior_spool_id]
      upsert? true
      upsert_identity :generation
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
    attribute :network_scope_id, :uuid, allow_nil?: false
    attribute :agent_id, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 256]
    attribute :prior_spool_id, :uuid, allow_nil?: false
    create_timestamp :inserted_at
  end

  identities do
    identity :generation, [:network_scope_id, :agent_id, :prior_spool_id]
  end
end
