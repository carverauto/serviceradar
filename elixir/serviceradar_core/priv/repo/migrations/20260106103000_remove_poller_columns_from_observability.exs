defmodule ServiceRadar.Repo.Migrations.RemovePollerColumnsFromObservability do
  @moduledoc """
  Removes poller columns and adds gateway columns for observability tables.
  """

  use Ecto.Migration

  def up do
    execute "ALTER TABLE IF EXISTS timeseries_metrics DROP COLUMN IF EXISTS poller_id"
    execute "ALTER TABLE IF EXISTS timeseries_metrics ADD COLUMN IF NOT EXISTS gateway_id TEXT NOT NULL"

    execute "ALTER TABLE IF EXISTS cpu_metrics DROP COLUMN IF EXISTS poller_id"
    execute "ALTER TABLE IF EXISTS cpu_metrics ADD COLUMN IF NOT EXISTS gateway_id TEXT NOT NULL"

    execute "ALTER TABLE IF EXISTS memory_metrics DROP COLUMN IF EXISTS poller_id"
    execute "ALTER TABLE IF EXISTS memory_metrics ADD COLUMN IF NOT EXISTS gateway_id TEXT"

    execute "ALTER TABLE IF EXISTS disk_metrics DROP COLUMN IF EXISTS poller_id"
    execute "ALTER TABLE IF EXISTS disk_metrics ADD COLUMN IF NOT EXISTS gateway_id TEXT"

    execute "ALTER TABLE IF EXISTS process_metrics DROP COLUMN IF EXISTS poller_id"
    execute "ALTER TABLE IF EXISTS process_metrics ADD COLUMN IF NOT EXISTS gateway_id TEXT"

    execute "ALTER TABLE IF EXISTS ocsf_network_activity DROP COLUMN IF EXISTS poller_id"
    execute "ALTER TABLE IF EXISTS ocsf_network_activity ADD COLUMN IF NOT EXISTS gateway_id TEXT"

    execute "DROP INDEX IF EXISTS ocsf_network_activity_poller_id_index"
    execute "CREATE INDEX IF NOT EXISTS ocsf_network_activity_gateway_id_index ON ocsf_network_activity (gateway_id) WHERE gateway_id IS NOT NULL"

    execute "ALTER TABLE IF EXISTS logs DROP COLUMN IF EXISTS poller_id"
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_class
        WHERE relname = 'otel_trace_summaries' AND relkind = 'r'
      ) THEN
        ALTER TABLE otel_trace_summaries DROP COLUMN IF EXISTS poller_id;
      END IF;
    END $$;
    """
    execute "ALTER TABLE IF EXISTS device_groups DROP COLUMN IF EXISTS poller_id"
  end

  def down do
    execute "ALTER TABLE IF EXISTS device_groups ADD COLUMN IF NOT EXISTS poller_id TEXT"
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_class
        WHERE relname = 'otel_trace_summaries' AND relkind = 'r'
      ) THEN
        ALTER TABLE otel_trace_summaries ADD COLUMN IF NOT EXISTS poller_id TEXT;
      END IF;
    END $$;
    """
    execute "ALTER TABLE IF EXISTS logs ADD COLUMN IF NOT EXISTS poller_id TEXT"

    execute "DROP INDEX IF EXISTS ocsf_network_activity_gateway_id_index"
    execute "ALTER TABLE IF EXISTS ocsf_network_activity DROP COLUMN IF EXISTS gateway_id"
    execute "ALTER TABLE IF EXISTS ocsf_network_activity ADD COLUMN IF NOT EXISTS poller_id TEXT"
    execute "CREATE INDEX IF NOT EXISTS ocsf_network_activity_poller_id_index ON ocsf_network_activity (poller_id) WHERE poller_id IS NOT NULL"

    execute "ALTER TABLE IF EXISTS process_metrics DROP COLUMN IF EXISTS gateway_id"
    execute "ALTER TABLE IF EXISTS process_metrics ADD COLUMN IF NOT EXISTS poller_id TEXT"

    execute "ALTER TABLE IF EXISTS disk_metrics DROP COLUMN IF EXISTS gateway_id"
    execute "ALTER TABLE IF EXISTS disk_metrics ADD COLUMN IF NOT EXISTS poller_id TEXT"

    execute "ALTER TABLE IF EXISTS memory_metrics DROP COLUMN IF EXISTS gateway_id"
    execute "ALTER TABLE IF EXISTS memory_metrics ADD COLUMN IF NOT EXISTS poller_id TEXT"

    execute "ALTER TABLE IF EXISTS cpu_metrics DROP COLUMN IF EXISTS gateway_id"
    execute "ALTER TABLE IF EXISTS cpu_metrics ADD COLUMN IF NOT EXISTS poller_id TEXT NOT NULL"

    execute "ALTER TABLE IF EXISTS timeseries_metrics DROP COLUMN IF EXISTS gateway_id"
    execute "ALTER TABLE IF EXISTS timeseries_metrics ADD COLUMN IF NOT EXISTS poller_id TEXT NOT NULL"
  end
end
