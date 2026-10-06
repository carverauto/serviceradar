defmodule ServiceRadar.Observability.AlertEvaluationWork do
  @moduledoc """
  Durably accepted stateful alert input and its immutable rule revision.

  A completion receipt and every lifecycle effect commit before this row is
  removed. Pending work has no destructive TTL and is never evicted to make
  room for a newer input. Rule removal is an explicit cancellation, not a
  cascading foreign-key deletion.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "alert_evaluation_work"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    create :admit do
      accept [
        :rule_id,
        :source_key,
        :position,
        :signal,
        :rule_revision,
        :payload,
        :payload_bytes,
        :available_at
      ]
    end

    update :retry do
      accept [:attempts, :available_at, :last_error]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    uuid_primary_key :id
    attribute :rule_id, :uuid, allow_nil?: false
    attribute :source_key, :string, allow_nil?: false, constraints: [max_length: 256]
    attribute :position, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :signal, :atom do
      allow_nil? false
      constraints one_of: [:log, :event, :metric, :maintenance, :cleanup]
    end

    attribute :rule_revision, :map, allow_nil?: false
    attribute :payload, :map, allow_nil?: false
    attribute :payload_bytes, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :attempts, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :available_at, :utc_datetime_usec, allow_nil?: false
    attribute :last_error, :string, constraints: [max_length: 2048]
    create_timestamp :accepted_at
  end

  identities do
    identity :rule_source, [:rule_id, :source_key]
    identity :rule_position, [:rule_id, :position]
  end
end
