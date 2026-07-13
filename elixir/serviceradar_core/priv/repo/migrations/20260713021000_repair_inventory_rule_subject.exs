defmodule ServiceRadar.Repo.Migrations.RepairInventoryRuleSubject do
  @moduledoc """
  Repairs the seeded `endpoint_inventory_vulnerability` stateful alert rule
  still pinned to the retired `signals.causal.inventory` subject family.

  Same defect class as 20260712110000 (which repaired only the
  `signals.causal.predictions` family): the emitter moved to
  `signals.analytics.inventory.*` in the de-causal rename, RuleSeeder was
  insert-if-absent at the time, and lazy adoption cannot fix it because the
  stored row's content has drifted from the shipped template. The legacy
  subject family has no producers left, so the rewrite is strictly
  reparative and idempotent (guarded on the exact legacy value).
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE #{schema()}.stateful_alert_rules
    SET match = jsonb_set(match, '{subject_prefix}', '"signals.analytics.inventory"')
    WHERE match ->> 'subject_prefix' = 'signals.causal.inventory'
    """)

    execute("""
    UPDATE #{schema()}.stateful_alert_rules
    SET match = jsonb_set(match, '{recovery,subject_prefix}', '"signals.analytics.inventory"')
    WHERE match #>> '{recovery,subject_prefix}' = 'signals.causal.inventory'
    """)
  end

  def down do
    :ok
  end

  defp schema do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Repo, [])
    |> Keyword.get(:migration_default_prefix, "platform")
  end
end
