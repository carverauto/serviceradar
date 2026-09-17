-- StarRocks primary-key table for migrated event / alert history.
-- Current alert state remains in CNPG and is not written here.
-- Applied by the Bazel schema target, not Mix/Postgres migrations.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.events (
  id VARCHAR(64) NOT NULL,
  `time` DATETIME NOT NULL,
  class_uid INT,
  category_uid INT,
  type_uid INT,
  activity_id INT,
  severity_id INT,
  severity VARCHAR(32),
  source VARCHAR(256),
  src_endpoint_ip VARCHAR(64),
  firewall_rule_name VARCHAR(256),
  source_type VARCHAR(64),
  message VARCHAR(65533),
  activity_name VARCHAR(128),
  status VARCHAR(64),
  status_id INT,
  log_name VARCHAR(256),
  log_provider VARCHAR(128),
  trace_id VARCHAR(64),
  span_id VARCHAR(64)
)
PRIMARY KEY (id, `time`)
PARTITION BY date_trunc('day', `time`)
DISTRIBUTED BY HASH(id) BUCKETS 16
ORDER BY (`time`, id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "365"
);
