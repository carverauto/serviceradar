-- StarRocks primary-key table for migrated OCSF flows.
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
-- `time` is part of the primary key because StarRocks requires the partition
-- column to be a primary-key column. partition_live_number is the retention
-- default; SERVICERADAR_STARROCKS_RETENTION_DAYS_FLOWS is applied on top at
-- boot. A warehouse created before partitioning is rebuilt onto this
-- definition at startup by PartitionRebuild, which reads this CREATE to do it.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.ocsf_network_activity (
  id VARCHAR(64) NOT NULL,
  `time` DATETIME NOT NULL,
  device_uid VARCHAR(256) NOT NULL,
  event_type VARCHAR(64),
  src_endpoint_ip VARCHAR(64),
  dst_endpoint_ip VARCHAR(64),
  src_endpoint_port INT,
  dst_endpoint_port INT,
  protocol_num INT,
  protocol_name VARCHAR(32),
  direction_label VARCHAR(32),
  dst_service_label VARCHAR(128),
  bytes_total BIGINT,
  packets_total BIGINT,
  start_time DATETIME,
  end_time DATETIME,
  src_as_number INT,
  dst_as_number INT,
  tcp_flags INT,
  `partition` VARCHAR(128),
  input_snmp INT,
  output_snmp INT,
  src_mac VARCHAR(64),
  dst_mac VARCHAR(64),
  src_mac_vendor VARCHAR(128),
  dst_mac_vendor VARCHAR(128),
  src_hosting_provider VARCHAR(128),
  dst_hosting_provider VARCHAR(128),
  protocol_source VARCHAR(64),
  direction_source VARCHAR(64),
  dst_service_source VARCHAR(64),
  src_prefix_tags VARCHAR(65533),
  dst_prefix_tags VARCHAR(65533),
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
PRIMARY KEY (id, `time`)
PARTITION BY date_trunc('day', `time`)
DISTRIBUTED BY HASH(id) BUCKETS 16
ORDER BY (`time`, id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "90"
);
