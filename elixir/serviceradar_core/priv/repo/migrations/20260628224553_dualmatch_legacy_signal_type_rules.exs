defmodule ServiceRadar.Repo.Migrations.DualmatchLegacySignalTypeRules do
  @moduledoc """
  Backfills already-seeded health-finding alert rules so the OpenSpec 1.1
  signal_type flip ("causal" -> "prediction", producer commit ~53) does not
  orphan them.

  Context
  -------
  `ServiceRadar.Observability.RuleSeeder` is insert-if-absent
  (`seed_rule_if_missing`). Fresh deployments are now seeded with a dual-match
  array `signal_type: ["causal", "prediction"]`, but long-lived deployments
  (e.g. demo) still have their `causal_prediction_health_finding` and
  `causal_capacity_health_finding` StatefulAlertRule rows pinned to the legacy
  scalar `signal_type: "causal"`. Once producers emit `"prediction"`, those rows
  stop matching and silently drop health incidents.

  This is a one-time data backfill that rewrites the legacy scalar to the
  dual-match array in both the primary `attribute_equals` block and the nested
  `recovery.attribute_equals` block (when a recovery block is present).

  Idempotency
  -----------
  Each statement is guarded on `jsonb_typeof(... ) = 'string'`, so a re-run or a
  fresh-seeded deployment (already an array) is a no-op. The recovery rewrite is
  additionally guarded so it only touches rows that actually carry a recovery
  block.

  Down
  ----
  `down/0` is intentionally a no-op. The forward change is NOT safely
  reversible: fresh deployments are seeded directly with the array form, so
  reverting to the scalar `"causal"` would corrupt those legitimately-seeded
  rows. The forward migration is itself idempotent, so a re-up after any rollback
  re-establishes the desired state.
  """
  use Ecto.Migration

  @rule_names ["causal_prediction_health_finding", "causal_capacity_health_finding"]
  @dual_match ~s(["causal", "prediction"])

  def up do
    rule_names = Enum.map_join(@rule_names, ", ", &"'#{&1}'")

    # Primary match block: match->attribute_equals->signal_type
    execute("""
    UPDATE #{schema()}.stateful_alert_rules
    SET match = jsonb_set(
      match,
      '{attribute_equals,signal_type}',
      '#{@dual_match}'::jsonb,
      false
    )
    WHERE name IN (#{rule_names})
      AND jsonb_typeof(match->'attribute_equals'->'signal_type') = 'string'
    """)

    # Recovery block (only when present):
    # match->recovery->attribute_equals->signal_type
    execute("""
    UPDATE #{schema()}.stateful_alert_rules
    SET match = jsonb_set(
      match,
      '{recovery,attribute_equals,signal_type}',
      '#{@dual_match}'::jsonb,
      false
    )
    WHERE name IN (#{rule_names})
      AND match ? 'recovery'
      AND jsonb_typeof(match->'recovery'->'attribute_equals'->'signal_type') = 'string'
    """)
  end

  def down do
    # Not safely reversible -- fresh deployments are seeded with the array form,
    # so reverting to the scalar would corrupt them. See @moduledoc.
    :ok
  end

  defp schema do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Repo, [])
    |> Keyword.get(:migration_default_prefix, "platform")
  end
end
