defmodule ServiceRadar.Repo.Migrations.RemovePromoteMissedSweepsRule do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM #{prefix()}.event_rules
    WHERE name = 'promote_missed_sweeps'
    """)

    execute("""
    DELETE FROM #{prefix()}.log_promotion_rules
    WHERE name = 'promote_missed_sweeps'
    """)

    execute("""
    DELETE FROM #{prefix()}.log_promotion_rule_templates
    WHERE name = 'promote_missed_sweeps'
    """)
  end

  def down do
    :ok
  end
end
