defmodule ServiceRadar.Repo.Migrations.FlipLegacySignalTypeRulesToPrediction do
  @moduledoc """
  Flips already-seeded health-finding alert rules onto the clean
  `signal_type: "prediction"` discriminator after the legacy `signals.causal.*`
  / `signal_type: "causal"` back-compat was removed.

  Context
  -------
  `ServiceRadar.Observability.RuleSeeder` is insert-if-absent
  (`seed_rule_if_missing`). Fresh deployments are now seeded directly with the
  scalar `signal_type: "prediction"`, but long-lived deployments (e.g. demo)
  still have their `causal_prediction_health_finding` and
  `causal_capacity_health_finding` StatefulAlertRule rows pinned to either the
  legacy scalar `signal_type: "causal"` or the interim dual-match array
  `signal_type: ["causal", "prediction"]`. With every producer now emitting only
  `"prediction"`, those legacy rows still match (the array did, the scalar
  `"causal"` no longer does), so this normalizes both forms to the clean scalar.

  This is a one-time data backfill that rewrites the legacy value to the scalar
  `"prediction"` in both the primary `attribute_equals` block and the nested
  `recovery.attribute_equals` block (when a recovery block is present).

  Idempotency
  -----------
  Each statement is guarded so it only touches rows whose `signal_type` is
  present and not already the scalar `"prediction"`. A re-run, a fresh-seeded
  deployment (already scalar `"prediction"`), or a row without a recovery block
  is a no-op.

  Down
  ----
  `down/0` is intentionally a no-op. The forward change is NOT safely
  reversible: fresh deployments are seeded directly with the `"prediction"`
  scalar, so reverting to the legacy `"causal"` value would corrupt those
  legitimately-seeded rows. The forward migration is itself idempotent, so a
  re-up after any rollback re-establishes the desired state.
  """
  use Ecto.Migration

  @rule_names ["causal_prediction_health_finding", "causal_capacity_health_finding"]
  @prediction ~s("prediction")

  def up do
    rule_names = Enum.map_join(@rule_names, ", ", &"'#{&1}'")

    # Primary match block: match->attribute_equals->signal_type
    execute("""
    UPDATE #{schema()}.stateful_alert_rules
    SET match = jsonb_set(
      match,
      '{attribute_equals,signal_type}',
      '#{@prediction}'::jsonb,
      false
    )
    WHERE name IN (#{rule_names})
      AND match->'attribute_equals' ? 'signal_type'
      AND match->'attribute_equals'->'signal_type' <> '#{@prediction}'::jsonb
    """)

    # Recovery block (only when present):
    # match->recovery->attribute_equals->signal_type
    execute("""
    UPDATE #{schema()}.stateful_alert_rules
    SET match = jsonb_set(
      match,
      '{recovery,attribute_equals,signal_type}',
      '#{@prediction}'::jsonb,
      false
    )
    WHERE name IN (#{rule_names})
      AND match ? 'recovery'
      AND match->'recovery'->'attribute_equals' ? 'signal_type'
      AND match->'recovery'->'attribute_equals'->'signal_type' <> '#{@prediction}'::jsonb
    """)
  end

  def down do
    # Not safely reversible -- fresh deployments are seeded with the "prediction"
    # scalar, so reverting to the legacy value would corrupt them. See @moduledoc.
    :ok
  end

  defp schema do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Repo, [])
    |> Keyword.get(:migration_default_prefix, "platform")
  end
end
