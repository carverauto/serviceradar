defmodule ServiceRadar.Edge.RecoveryGeneration do
  @moduledoc "Serializes bounded recovery intervals over one frozen source generation."

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_generations"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :freeze do
      accept [
        :network_scope_id,
        :agent_id,
        :prior_spool_id,
        :route_profile,
        :traffic_class,
        :source_high_water,
        :reclaim_watermark,
        :applied_through
      ]

      upsert? true
      upsert_identity :generation_identity
      upsert_fields []
    end

    update :advance do
      accept [:applied_through]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    uuid_primary_key :id
    attribute :network_scope_id, :uuid, allow_nil?: false
    attribute :agent_id, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 256]
    attribute :prior_spool_id, :uuid, allow_nil?: false
    attribute :route_profile, :integer, allow_nil?: false
    attribute :traffic_class, :integer, allow_nil?: false
    # Protobuf uint64 exceeds PostgreSQL bigint. Numeric keeps the full exact
    # sequence space; registration validates integer range before persistence.
    attribute :source_high_water, :decimal, allow_nil?: false
    attribute :reclaim_watermark, :decimal, allow_nil?: false
    attribute :applied_through, :decimal, allow_nil?: false
    timestamps()
  end

  identities do
    identity :generation_identity, [:network_scope_id, :agent_id, :prior_spool_id]
  end
end
