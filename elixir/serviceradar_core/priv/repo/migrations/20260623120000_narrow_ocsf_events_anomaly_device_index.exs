defmodule ServiceRadar.Repo.Migrations.NarrowOcsfEventsAnomalyDeviceIndex do
  @moduledoc """
  Narrow the device-anomaly-panel index to source_type = 'anomaly_detection'.

  `idx_ocsf_events_sr_device_uid_time` was partial on `class_uid = 2004`, but
  class_uid 2004 (OCSF Detection Finding) also holds `capacity_forecasting` and
  `falco` findings. The device-detail anomaly panel always filters
  `source_type = 'anomaly_detection'`, which compiled to a heap `Filter` ON TOP of
  the index (source_type lives in metadata, not the index).

  For a `device_uid` whose class_uid 2004 events are mostly NOT anomaly_detection,
  the panel's `ORDER BY time DESC LIMIT 20` walked every index entry for that
  device, heap-fetching source_type, and removed them all. Observed on demo for
  the `default` device_uid bucket: 72,668 class_uid 2004 events, 0 anomalies,
  `Rows Removed by Filter: 72668`, ~0.65s in isolation and 2-4.5s under load —
  exceeding the panel's 5000ms SRQL task timeout ("anomaly SRQL query timed out").

  Add `source_type = 'anomaly_detection'` to the partial predicate so the index
  only contains anomaly rows and the scan walks only those for the device_uid.
  Verified on demo: the `default` case drops from ~650ms to 0.14ms; a populated
  device stays at ~0.16ms. The anomaly panel is the only consumer of this index
  (the capacity panel filters `resource_id` against `capacity_forecasts`, not
  device_uid against ocsf_events), so narrowing is safe.
  """

  use Ecto.Migration

  # Timescale hypertables do not support CREATE INDEX CONCURRENTLY. Build the new
  # (narrower) index first, then drop the old one, so the panel query always has
  # an index to use during the migration.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @table "ocsf_events"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_sr_anomaly_device_time
    ON #{@schema}.#{@table} ((metadata #>> '{service_radar,device_uid}'), time DESC)
    WHERE class_uid = 2004
      AND (metadata #>> '{service_radar,source_type}') = 'anomaly_detection'
    """)

    execute("DROP INDEX IF EXISTS #{@schema}.idx_ocsf_events_sr_device_uid_time")
  end

  def down do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_sr_device_uid_time
    ON #{@schema}.#{@table} ((metadata #>> '{service_radar,device_uid}'), time DESC)
    WHERE class_uid = 2004
    """)

    execute("DROP INDEX IF EXISTS #{@schema}.idx_ocsf_events_sr_anomaly_device_time")
  end
end
