-- StarRocks primary-key table for migrated event / alert history.
-- Current alert state remains in CNPG and is not written here.
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.events (
  id VARCHAR(64) NOT NULL,
  `time` DATETIME NOT NULL,
  class_uid INT,
  category_uid INT,
  type_uid INT,
  activity_id INT,
  severity_id INT,
  severity VARCHAR(1048576),
  source VARCHAR(1048576),
  src_endpoint_ip VARCHAR(64),
  firewall_rule_name VARCHAR(1048576),
  source_type VARCHAR(1048576),
  message VARCHAR(1048576),
  activity_name VARCHAR(1048576),
  status VARCHAR(1048576),
  status_id INT,
  log_name VARCHAR(1048576),
  log_provider VARCHAR(1048576),
  trace_id VARCHAR(64),
  span_id VARCHAR(64),
  log_level VARCHAR(1048576),
  metadata VARCHAR(1048576),
  unmapped VARCHAR(1048576),
  device VARCHAR(1048576),
  observables VARCHAR(1048576),
  status_code VARCHAR(1048576),
  status_detail VARCHAR(1048576),
  log_version VARCHAR(1048576),
  actor VARCHAR(1048576),
  src_endpoint VARCHAR(1048576),
  dst_endpoint VARCHAR(1048576),
  raw_data VARCHAR(1048576),
  created_at DATETIME
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
