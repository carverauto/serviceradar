-- StarRocks primary-key table for migrated logs.
-- Applied by the Bazel schema target, not Mix/Postgres migrations.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.logs (
  id VARCHAR(64) NOT NULL,
  `timestamp` DATETIME NOT NULL,
  ingest_identity VARCHAR(256) NOT NULL,
  severity_text VARCHAR(32),
  severity_number INT,
  body VARCHAR(65533),
  service_name VARCHAR(256),
  source VARCHAR(256),
  ingest_agent_id VARCHAR(256),
  ingest_partition VARCHAR(128),
  trace_id VARCHAR(64),
  span_id VARCHAR(64),
  event_name VARCHAR(256),
  source_ip VARCHAR(64),
  service_version VARCHAR(64),
  observed_timestamp DATETIME
)
PRIMARY KEY (id, `timestamp`)
PARTITION BY date_trunc('day', `timestamp`)
DISTRIBUTED BY HASH(id) BUCKETS 16
ORDER BY (`timestamp`, id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "90"
);
