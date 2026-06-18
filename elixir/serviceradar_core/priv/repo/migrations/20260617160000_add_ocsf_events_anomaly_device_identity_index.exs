defmodule ServiceRadar.Repo.Migrations.AddOcsfEventsAnomalyDeviceIdentityIndex do
  @moduledoc """
  Index-serves the device anomaly panel's canonical device lookup.

  The device-detail anomaly/capacity panel filters `platform.ocsf_events` by the
  canonical device uid. Before the ingest re-key + SRQL anchoring, that filter
  compiled to a leading-wildcard `metadata::text ILIKE '%...%'`, which is
  non-indexable and seq-scanned the 13GB OCSF hypertable (~15.6s, exceeding the
  30s statement_timeout under load).

  After re-keying anomaly/capacity detection findings under the canonical
  `device.uid` / `metadata.service_radar.device_uid`, SRQL filters those rows with
  an anchored equality on `metadata #>> '{service_radar,device_uid}'`. This partial
  expression index makes that equality a range scan instead of a chunk seq-scan.
  It is scoped to `class_uid = 2004` (OCSF Detection Finding) so it stays narrow
  and only covers the anomaly/capacity finding rows the panel queries.
  """

  use Ecto.Migration

  # Timescale hypertables do not support CREATE INDEX CONCURRENTLY. Keep this
  # migration outside the transaction/lock path, but build the index normally.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @table "ocsf_events"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_sr_device_uid_time
    ON #{@schema}.#{@table} ((metadata #>> '{service_radar,device_uid}'), time DESC)
    WHERE class_uid = 2004
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@schema}.idx_ocsf_events_sr_device_uid_time")
  end
end
