-- StarRocks primary-key table for migrated scalar metrics.
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
-- Identity matches CNPG: (timestamp, gateway_id, series_key).
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
DISTRIBUTED BY HASH(series_key) BUCKETS 16
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "90"
);
