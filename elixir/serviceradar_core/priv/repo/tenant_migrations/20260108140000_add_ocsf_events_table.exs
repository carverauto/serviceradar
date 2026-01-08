defmodule ServiceRadar.Repo.TenantMigrations.AddOcsfEventsTable do
  @moduledoc """
  Creates OCSF events table in tenant schemas for audit trail and event logging.

  This table stores OCSF Event Log Activity (class_uid: 1008) records including:
  - Audit trail events (config changes, user actions)
  - Syslog events
  - SNMP trap events

  Uses TimescaleDB hypertable for efficient time-series queries.
  """

  use Ecto.Migration

  def up do
    schema = prefix() || "public"

    execute """
    CREATE TABLE IF NOT EXISTS #{schema}.ocsf_events (
      id                  UUID              PRIMARY KEY,
      time                TIMESTAMPTZ       NOT NULL,
      class_uid           INTEGER           NOT NULL,
      category_uid        INTEGER           NOT NULL,
      type_uid            INTEGER           NOT NULL,
      activity_id         INTEGER           NOT NULL,
      activity_name       TEXT,
      severity_id         INTEGER           NOT NULL DEFAULT 1,
      severity            TEXT,
      message             TEXT,
      status_id           INTEGER,
      status              TEXT,
      status_code         TEXT,
      status_detail       TEXT,
      metadata            JSONB,
      observables         JSONB,
      trace_id            TEXT,
      span_id             TEXT,
      actor               JSONB,
      device              JSONB,
      src_endpoint        JSONB,
      dst_endpoint        JSONB,
      log_name            TEXT,
      log_provider        TEXT,
      log_level           TEXT,
      log_version         TEXT,
      unmapped            JSONB,
      raw_data            TEXT,
      tenant_id           UUID              NOT NULL,
      created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    # Create indexes for common query patterns
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_events_time ON #{schema}.ocsf_events (time DESC)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_events_class_uid ON #{schema}.ocsf_events (class_uid)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_events_severity_id ON #{schema}.ocsf_events (severity_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_events_log_name ON #{schema}.ocsf_events (log_name)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_events_tenant_id ON #{schema}.ocsf_events (tenant_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_events_activity_id ON #{schema}.ocsf_events (activity_id)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_events_metadata_gin ON #{schema}.ocsf_events USING gin (metadata)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_events_unmapped_gin ON #{schema}.ocsf_events USING gin (unmapped)"
    execute "CREATE INDEX IF NOT EXISTS idx_ocsf_events_observables_gin ON #{schema}.ocsf_events USING gin (observables)"

    # Try to create hypertable if TimescaleDB is available
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
        PERFORM create_hypertable('#{schema}.ocsf_events', 'time', if_not_exists => TRUE);
      END IF;
    END
    $$;
    """
  end

  def down do
    schema = prefix() || "public"
    execute "DROP TABLE IF EXISTS #{schema}.ocsf_events CASCADE"
  end
end
