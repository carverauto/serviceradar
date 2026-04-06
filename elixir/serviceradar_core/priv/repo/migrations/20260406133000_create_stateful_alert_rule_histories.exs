defmodule ServiceRadar.Repo.Migrations.CreateStatefulAlertRuleHistories do
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{@prefix}.stateful_alert_rule_histories (
      id UUID NOT NULL DEFAULT gen_random_uuid(),
      event_time TIMESTAMPTZ NOT NULL,
      rule_id UUID NOT NULL,
      group_key TEXT NOT NULL,
      event_type TEXT NOT NULL,
      alert_id UUID,
      details JSONB NOT NULL DEFAULT '{}'::jsonb,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (event_time, id)
    )
    """)

    ensure_table_ownership("stateful_alert_rule_histories")
    maybe_create_hypertable("stateful_alert_rule_histories", "event_time")

    execute("""
    CREATE INDEX IF NOT EXISTS idx_stateful_alert_rule_histories_rule_time
    ON #{@prefix}.stateful_alert_rule_histories (rule_id, event_time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_stateful_alert_rule_histories_group_time
    ON #{@prefix}.stateful_alert_rule_histories (group_key, event_time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_stateful_alert_rule_histories_event_type_time
    ON #{@prefix}.stateful_alert_rule_histories (event_type, event_time DESC)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@prefix}.idx_stateful_alert_rule_histories_event_type_time")
    execute("DROP INDEX IF EXISTS #{@prefix}.idx_stateful_alert_rule_histories_group_time")
    execute("DROP INDEX IF EXISTS #{@prefix}.idx_stateful_alert_rule_histories_rule_time")
    execute("DROP TABLE IF EXISTS #{@prefix}.stateful_alert_rule_histories")
  end

  defp maybe_create_hypertable(table_name, time_column) do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL THEN
        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_name = '#{table_name}'
            AND hypertable_schema = '#{@prefix}'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{@prefix}.#{table_name}',
            '#{time_column}'
          );
        END IF;
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create hypertable for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp ensure_table_ownership(table_name) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_tables
        WHERE tablename = '#{table_name}'
          AND schemaname = '#{@prefix}'
      ) THEN
        EXECUTE format('ALTER TABLE %I.%I OWNER TO CURRENT_USER', '#{@prefix}', '#{table_name}');
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not change ownership for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
