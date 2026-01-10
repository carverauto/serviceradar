defmodule ServiceRadar.Repo.TenantMigrations.AddStatefulAlertRuleHistory do
  @moduledoc """
  Creates the stateful alert rule evaluation history hypertable.
  """

  use Ecto.Migration

  def up do
    schema = prefix() || "public"

    execute "DROP TABLE IF EXISTS #{schema}.stateful_alert_rule_history CASCADE"

    execute """
    CREATE TABLE #{schema}.stateful_alert_rule_history (
      id          UUID        NOT NULL,
      event_time  TIMESTAMPTZ NOT NULL,
      rule_id     UUID        NOT NULL,
      group_key   TEXT        NOT NULL,
      event_type  TEXT        NOT NULL,
      alert_id    UUID,
      details     JSONB,
      tenant_id   UUID        NOT NULL,
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (id, event_time)
    )
    """

    execute "CREATE INDEX IF NOT EXISTS idx_stateful_alert_rule_history_event_time ON #{schema}.stateful_alert_rule_history (event_time DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_stateful_alert_rule_history_rule_id ON #{schema}.stateful_alert_rule_history (rule_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_stateful_alert_rule_history_group_key ON #{schema}.stateful_alert_rule_history (group_key)"
    execute "CREATE INDEX IF NOT EXISTS idx_stateful_alert_rule_history_tenant_id ON #{schema}.stateful_alert_rule_history (tenant_id)"

    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
        PERFORM create_hypertable('#{schema}.stateful_alert_rule_history', 'event_time', if_not_exists => TRUE);
        EXECUTE 'ALTER TABLE #{schema}.stateful_alert_rule_history SET (timescaledb.compress, timescaledb.compress_segmentby = ''rule_id'', timescaledb.compress_orderby = ''event_time DESC'')';

        BEGIN
          PERFORM add_retention_policy('#{schema}.stateful_alert_rule_history', INTERVAL '7 days', if_not_exists => TRUE);
        EXCEPTION
          WHEN undefined_function THEN
            NULL;
        END;

        BEGIN
          PERFORM add_compression_policy('#{schema}.stateful_alert_rule_history', INTERVAL '1 day', if_not_exists => TRUE);
        EXCEPTION
          WHEN undefined_function THEN
            NULL;
        END;
      END IF;
    END
    $$;
    """
  end

  def down do
    schema = prefix() || "public"
    execute "DROP TABLE IF EXISTS #{schema}.stateful_alert_rule_history CASCADE"
  end
end
