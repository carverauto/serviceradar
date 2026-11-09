defmodule ServiceRadar.Edge.RecoveryRegistration do
  @moduledoc "Immutable recovery intent and its serialized consumer progress, independent of agent lifecycle rows."

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_recovery_registrations"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:network_scope_id, :agent_id, :prior_spool_id, :interval_registered, :from_sequence]
    end
  end

  actions do
    defaults [:read]

    create :register do
      accept [
        :network_scope_id,
        :agent_id,
        :recovery_id,
        :registration,
        :prior_spool_id,
        :from_sequence,
        :through_sequence
      ]

      upsert? true
      upsert_identity :recovery_identity
      upsert_fields []
    end

    update :admit_interval do
      accept []
      change set_attribute(:interval_registered, true)
    end

    update :block do
      accept [:blocked_reason]
    end

    update :receive_tombstone do
      accept []
      change set_attribute(:tombstone_received, true)
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
    attribute :registration, :binary, allow_nil?: false
    attribute :interval_registered, :boolean, allow_nil?: false, default: false
    attribute :prior_spool_id, :uuid, allow_nil?: false
    attribute :from_sequence, :decimal, allow_nil?: false
    attribute :through_sequence, :decimal, allow_nil?: false
    attribute :blocked_reason, :string, constraints: [max_length: 128]
    attribute :tombstone_received, :boolean, allow_nil?: false, default: false
    timestamps()
  end

  identities do
    identity :recovery_identity, [:network_scope_id, :agent_id, :recovery_id]
  end
end
