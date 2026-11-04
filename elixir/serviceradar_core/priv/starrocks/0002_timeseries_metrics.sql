-- StarRocks primary-key table for migrated scalar metrics.
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
-- Identity matches CNPG: (timestamp, gateway_id, series_key).
--
-- Sorted by (metric_type, metric_name, device_id, timestamp), not by that key:
-- every metric reader names metric_type and metric_name, and the device panels
-- a device_id too, so the short-key index and page zone maps skip everything
-- but the series asked for instead of reading the whole day partition. Only
-- the sort key differs from the key; the identity Stream Load upserts on and
-- the column list it names are unchanged. A table created before the sort key
-- was shipped is rebuilt onto it, an hour a statement, by
-- ServiceRadar.Analytics.StarRocks.PartitionRebuild.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.timeseries_metrics (
  `timestamp` DATETIME NOT NULL,
  gateway_id VARCHAR(256) NOT NULL,
  series_key VARCHAR(512) NOT NULL,
  agent_id VARCHAR(256),
  metric_name VARCHAR(256) NOT NULL,
  metric_type VARCHAR(64) NOT NULL,
  device_id VARCHAR(256),
  value DOUBLE NOT NULL,
  unit VARCHAR(64),
  if_index INT,
  `partition` VARCHAR(128),
  scale DOUBLE,
  is_delta BOOLEAN,
  counter_width INT,
  target_device_ip VARCHAR(64),
  tags VARCHAR(65533)
)
PRIMARY KEY (`timestamp`, gateway_id, series_key)
PARTITION BY date_trunc('day', `timestamp`)
DISTRIBUTED BY HASH(series_key) BUCKETS 4
ORDER BY (metric_type, metric_name, device_id, `timestamp`)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "90"
);
