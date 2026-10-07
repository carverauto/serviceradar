defmodule ServiceRadar.Observability.AlertEvaluationLane do
  @moduledoc """
  Committed input order for a stateful alert rule.

  Admission advances this row under its own short transaction lock. Evaluation
  ownership uses a separate fence so a slow evaluator never holds this row.
  The rule identity deliberately survives deletion for replay-safe receipts.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "alert_evaluation_lanes"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :register do
      accept [:rule_id]
      upsert? true
      upsert_identity :rule
      upsert_fields []
    end

    update :reserve do
      accept [:next_position]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    attribute :rule_id, :uuid do
      primary_key? true
      allow_nil? false
    end

    attribute :next_position, :integer do
      allow_nil? false
      default 0
      constraints min: 0
    end

    attribute :cancelled_through, :integer do
      allow_nil? false
      default 0
      constraints min: 0
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :rule, [:rule_id]
  end
end
