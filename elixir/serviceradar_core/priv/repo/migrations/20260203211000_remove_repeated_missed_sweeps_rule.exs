defmodule ServiceRadar.Repo.Migrations.RemoveRepeatedMissedSweepsRule do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = '#{prefix()}' AND table_name = 'stateful_alert_rule_states'
      ) AND EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = '#{prefix()}' AND table_name = 'stateful_alert_rules'
      ) THEN
        DELETE FROM #{prefix()}.stateful_alert_rule_states
        WHERE rule_id IN (
          SELECT id FROM #{prefix()}.stateful_alert_rules WHERE name = 'repeated_missed_sweeps'
        );
      END IF;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = '#{prefix()}' AND table_name = 'stateful_alert_rule_histories'
      ) AND EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = '#{prefix()}' AND table_name = 'stateful_alert_rules'
      ) THEN
        DELETE FROM #{prefix()}.stateful_alert_rule_histories
        WHERE rule_id IN (
          SELECT id FROM #{prefix()}.stateful_alert_rules WHERE name = 'repeated_missed_sweeps'
        );
      END IF;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = '#{prefix()}' AND table_name = 'stateful_alert_rules'
      ) THEN
        DELETE FROM #{prefix()}.stateful_alert_rules
        WHERE name = 'repeated_missed_sweeps';
      END IF;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = '#{prefix()}' AND table_name = 'stateful_alert_rule_templates'
      ) THEN
        DELETE FROM #{prefix()}.stateful_alert_rule_templates
        WHERE name = 'repeated_missed_sweeps';
      END IF;
    END
    $$;
    """)
  end

  def down do
    :ok
  end
end
