defmodule ServiceRadar.Observability.AlertEvaluationReceipt do
  @moduledoc """
  Durable completion or audited terminal disposition of accepted alert input.

  A receipt is committed in the same owner transaction as snapshots, alerts,
  history and outbox work. Its identity follows the source occurrence and rule,
  independently of batch boundaries. Retention must cover the supported source
  replay horizon; JetStream's short duplicate window is not that horizon.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "alert_evaluation_receipts"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      accept [:rule_id, :source_key, :position, :disposition, :details, :resolved_count]
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

    attribute :disposition, :atom do
      allow_nil? false
      constraints one_of: [:completed, :cancelled, :failed]
    end

    attribute :details, :map, allow_nil?: false, default: %{}
    attribute :resolved_count, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    create_timestamp :completed_at
  end

  identities do
    identity :rule_source, [:rule_id, :source_key]
  end
end
