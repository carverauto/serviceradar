defmodule ServiceRadar.Edge.RecoveryReceivedPage do
  @moduledoc "The first validated recovery page received through JetStream, keyed only by its identity."

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_received_pages"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :receive do
      accept [:network_scope_id, :agent_id, :recovery_id, :page_index, :page_sha256, :payload]
      upsert? true
      upsert_identity :page_identity
      upsert_fields []
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
    attribute :recovery_id, :uuid, allow_nil?: false
    attribute :page_index, :integer, allow_nil?: false, constraints: [min: 0, max: 1023]
    attribute :page_sha256, :binary, allow_nil?: false
    attribute :payload, :binary, allow_nil?: false
    create_timestamp :inserted_at
  end

  identities do
    identity :page_identity, [:network_scope_id, :agent_id, :recovery_id, :page_index]
  end
end
