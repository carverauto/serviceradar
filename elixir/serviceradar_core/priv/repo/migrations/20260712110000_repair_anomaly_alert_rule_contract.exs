defmodule ServiceRadar.Repo.Migrations.RepairAnomalyAlertRuleContract do
  @moduledoc """
  Repairs already-seeded stateful alert rules still pinned to the retired
  `signals.causal.predictions` subject family and stamps the two
  prediction-contract rules with the managed-rule reconciliation marker.

  Context
  -------
  `ServiceRadar.Observability.RuleSeeder` was insert-if-absent
  (`seed_rule_if_missing`) until managed-rule reconciliation shipped, so
  long-lived deployments (e.g. demo) still carry `subject_prefix` values
  pinned to `signals.causal.predictions` even though every producer moved to
  `signals.analytics.predictions` in the de-causal identifier sweep. A rule
  matching a dead subject family can never fire or recover.

  Two repairs:

  1. Rewrite `subject_prefix` from the legacy `signals.causal.predictions` to
     `signals.analytics.predictions` wherever the current value is exactly the
     legacy string — independently in the primary `match` block and the nested
     `match->recovery` block. The legacy subject family has no producers left,
     so the rewrite is strictly reparative.

  2. Add the managed-rule columns (`managed`, `template_version`,
     `template_fingerprint`) and stamp ONLY the two prediction-contract rules
     this migration repairs (`causal_prediction_health_finding`,
     `causal_capacity_health_finding`) as managed at `template_version` 0.
     The seeder treats version 0 with no fingerprint on those two names as
     the pre-marker state and reconciles them to the current template exactly
     once on the next boot. Other seeded rule names (e.g.
     `falco_critical_incident`) are intentionally NOT stamped: stamping by
     name alone would let the seeder overwrite operator-customized content;
     the seeder instead adopts pristine rows lazily when their content
     already matches the shipped template. Operators detach a rule from the
     seeder by clearing `managed`.

  Idempotency
  -----------
  The columns are added with `add_if_not_exists`. The prefix rewrites only
  touch rows whose value is exactly the legacy string. The managed stamp only
  touches rows that are not yet managed and carry no `template_version`, so a
  re-run after the seeder has reconciled the rules to a newer version is a
  no-op.

  Down
  ----
  Removes the managed-rule columns. The `subject_prefix` rewrite is NOT
  reversed: the legacy subject family is dead, so restoring it would only
  recreate rules that can never match.
  """

  use Ecto.Migration

  @legacy_prefix "signals.causal.predictions"
  @current_prefix ~s("signals.analytics.predictions")

  # The two producer-contract rules this migration repairs: their
  # subject_prefix is rewritten below, so a one-time template adoption on the
  # next boot is safe and required. Other seeder-owned names are left
  # unstamped so operator-customized content is never overwritten.
  @contract_rule_names [
    "causal_prediction_health_finding",
    "causal_capacity_health_finding"
  ]

  def up do
    alter table(:stateful_alert_rules, prefix: schema()) do
      add_if_not_exists :managed, :boolean, null: false, default: false
      add_if_not_exists :template_version, :integer
      add_if_not_exists :template_fingerprint, :text
    end

    # Primary match block: match->subject_prefix
    execute("""
    UPDATE #{schema()}.stateful_alert_rules
    SET match = jsonb_set(
      match,
      '{subject_prefix}',
      '#{@current_prefix}'::jsonb,
      false
    )
    WHERE match->>'subject_prefix' = '#{@legacy_prefix}'
    """)

    # Recovery block (only when present): match->recovery->subject_prefix
    execute("""
    UPDATE #{schema()}.stateful_alert_rules
    SET match = jsonb_set(
      match,
      '{recovery,subject_prefix}',
      '#{@current_prefix}'::jsonb,
      false
    )
    WHERE match->'recovery'->>'subject_prefix' = '#{@legacy_prefix}'
    """)

    rule_names = Enum.map_join(@contract_rule_names, ", ", &"'#{&1}'")

    execute("""
    UPDATE #{schema()}.stateful_alert_rules
    SET managed = true, template_version = 0
    WHERE name IN (#{rule_names})
      AND NOT managed
      AND template_version IS NULL
    """)
  end

  def down do
    # The subject_prefix rewrite is intentionally not reversed. See @moduledoc.
    alter table(:stateful_alert_rules, prefix: schema()) do
      remove :managed
      remove :template_version
      remove :template_fingerprint
    end
  end

  defp schema do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Repo, [])
    |> Keyword.get(:migration_default_prefix, "platform")
  end
end
