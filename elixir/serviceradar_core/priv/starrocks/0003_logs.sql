-- StarRocks primary-key table for migrated logs.
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.logs (
  id VARCHAR(64) NOT NULL,
  `timestamp` DATETIME NOT NULL,
  ingest_identity VARCHAR(1048576) NOT NULL,
  severity_text VARCHAR(1048576),
  severity_number INT,
  body VARCHAR(1048576),
  service_name VARCHAR(1048576),
  source VARCHAR(1048576),
  ingest_agent_id VARCHAR(1048576),
  ingest_partition VARCHAR(1048576),
  trace_id VARCHAR(64),
  span_id VARCHAR(64),
  event_name VARCHAR(1048576),
  source_ip VARCHAR(64),
  service_version VARCHAR(1048576),
  observed_timestamp DATETIME
)
PRIMARY KEY (id, `timestamp`)
PARTITION BY date_trunc('day', `timestamp`)
DISTRIBUTED BY HASH(id) BUCKETS 16
ORDER BY (`timestamp`, id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "365"
);
