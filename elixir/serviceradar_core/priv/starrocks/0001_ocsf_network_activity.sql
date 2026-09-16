-- StarRocks primary-key table for migrated OCSF flows.
-- Applied by the Bazel schema target, not Mix/Postgres migrations.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.ocsf_network_activity (
  id VARCHAR(64) NOT NULL,
  device_uid VARCHAR(256) NOT NULL,
  time DATETIME NOT NULL,
  src_endpoint_ip VARCHAR(64),
  dst_endpoint_ip VARCHAR(64),
  bytes_in BIGINT,
  bytes_out BIGINT,
  packets_in BIGINT,
  packets_out BIGINT,
  sampling_rate INT,
  attribution_version BIGINT DEFAULT "0",
  sampler_address VARCHAR(64),
  pid INT,
  comm VARCHAR(256),
  cmdline VARCHAR(65533),
  workload_identity VARCHAR(65533)
)
PRIMARY KEY (id)
DISTRIBUTED BY HASH(id) BUCKETS 16
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true"
);
