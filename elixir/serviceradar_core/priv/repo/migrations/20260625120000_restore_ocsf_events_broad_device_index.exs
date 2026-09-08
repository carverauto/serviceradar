defmodule ServiceRadar.Repo.Migrations.RestoreOcsfEventsBroadDeviceIndex do
  @moduledoc """
  Restore the broad device-anomaly index dropped by
  NarrowOcsfEventsAnomalyDeviceIndex (20260623120000).

  That migration narrowed `idx_ocsf_events_sr_device_uid_time` to additionally
  require `(metadata #>> '{service_radar,source_type}') = 'anomaly_detection'`
  in the partial predicate, on the assumption the device Anomaly & Capacity panel
  filters source_type as a SINGLE equality the planner could push into the index.
  It does not. The SRQL `source_type:anomaly_detection` token compiles to a
  NINE-way OR:

      log_provider = 'anomaly_detection'
      OR log_name = 'anomaly_detection'
      OR metadata #>> '{service_radar,source_type}' = 'anomaly_detection'
      OR metadata #>> '{service_radar,addon_id}'   = 'anomaly_detection'
      OR metadata #>> '{serviceradar,source_type}' = 'anomaly_detection'
      OR metadata #>> '{serviceradar,addon_id}'    = 'anomaly_detection'
      OR metadata ->> 'source'      = 'anomaly_detection'
      OR unmapped ->> 'source_type' = 'anomaly_detection'
      OR unmapped ->> 'addon_id'    = 'anomaly_detection'

  An OR cannot imply the narrow index's partial predicate, so the narrow index is
  unusable for the actual query. EXPLAIN of the real generated SQL falls back to
  `ocsf_events_time_idx` and scans the full 7-day window (cost ~4.3M on one chunk),
  exceeding the panel's 5000ms SRQL task timeout for ALL devices ("anomaly SRQL
  query timed out after 5000ms").

  Restore the broad `(device_uid, time DESC) WHERE class_uid = 2004` index. The
  query's `class_uid = 2004` DOES imply this partial, `device_uid = X` seeks the
  leading key, time DESC satisfies the ORDER BY, and the 9-way OR collapses to a
  cheap residual Filter over only that device's class_uid 2004 rows (small for a
  real device). The narrow index is intentionally left in place for any future
  consumer that filters source_type as a single pushed-down predicate.

  Timescale hypertables reject CREATE INDEX CONCURRENTLY, so this is a plain
  per-chunk build (brief write lock).
  """
  use Ecto.Migration

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
