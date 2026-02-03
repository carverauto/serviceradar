defmodule ServiceRadar.Repo.Migrations.RemoveRepeatedMissedSweepsRule do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM #{prefix()}.stateful_alert_rule_states
    WHERE rule_id IN (
      SELECT id FROM #{prefix()}.stateful_alert_rules WHERE name = 'repeated_missed_sweeps'
    )
    """)

    execute("""
    DELETE FROM #{prefix()}.stateful_alert_rule_histories
    WHERE rule_id IN (
      SELECT id FROM #{prefix()}.stateful_alert_rules WHERE name = 'repeated_missed_sweeps'
    )
    """)

    execute("""
    DELETE FROM #{prefix()}.stateful_alert_rules
    WHERE name = 'repeated_missed_sweeps'
    """)

    execute("""
    DELETE FROM #{prefix()}.stateful_alert_rule_templates
    WHERE name = 'repeated_missed_sweeps'
    """)
  end

  def down do
    :ok
  end
end
