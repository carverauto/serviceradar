defmodule ServiceRadar.Repo.Migrations.ExtendAnomalyAlertRuleDriftLifecycleStates do
  @moduledoc """
  Extends already-seeded anomaly alert rules to understand the edge drift episode
  lifecycle names introduced by the anomaly-engine reliability overhaul.

  `RuleSeeder` is insert-if-absent, so long-lived deployments keep their existing
  `causal_prediction_health_finding` row unless a migration patches it. Fresh
  deployments are seeded with these values directly.

  The migration is intentionally forward-only and idempotent. It appends missing
  values instead of replacing the whole matcher, preserving any operator-added
  states on the seeded rule.
  """
  use Ecto.Migration

  @rule_name "causal_prediction_health_finding"

  def up do
    append_missing_lifecycle_state(
      "{attribute_equals,anomaly.state}",
      "anomaly_drift_open"
    )

    append_missing_lifecycle_state(
      "{recovery,attribute_equals,anomaly.state}",
      "anomaly_drift_clear"
    )
  end

  def down do
    # Not safely reversible: fresh deployments are seeded with these states, and
    # operator-customized match arrays may legitimately contain them.
    :ok
  end

  defp append_missing_lifecycle_state(path, value) do
    execute("""
    UPDATE #{schema()}.stateful_alert_rules
    SET match = jsonb_set(
      match,
      '#{path}',
      (match #> '#{path}') || '[#{Jason.encode!(value)}]'::jsonb,
      false
    )
    WHERE name = '#{@rule_name}'
      AND match #> '#{path}' IS NOT NULL
      AND NOT COALESCE((match #> '#{path}') ? '#{value}', false)
    """)
  end

  defp schema do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Repo, [])
    |> Keyword.get(:migration_default_prefix, "platform")
  end
end
