-- StarRocks primary-key tables for MTR traces and their hops.
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
--
-- Column names are those of platform.mtr_traces and platform.mtr_hops, so a
-- reader can serve either backend from the same row shape. EventWriter's Mtr
-- processor writes here, and only here, when StarRocks is enabled; otherwise
-- it writes CNPG. Both tables are built by MtrMetricsIngestor.rows/3, the
-- function the CNPG insert uses.
--
-- The key is (id, `time`), as for the other telemetry tables: StarRocks
-- requires the partition column in the primary key. A trace id is the
-- publisher's trace_uuid and a hop id is derived from that id and the hop's
-- position, so a redelivered message upserts the rows it already loaded.
-- A hop is stored at its trace's time, so `time` then trace_id is the sort key
-- a trace-detail read by (trace_id, time) prunes on.
--
-- partition_live_number is the retention default, the MTR history default of
-- MtrSettings; SERVICERADAR_STARROCKS_RETENTION_DAYS_MTR is applied on top at
-- boot, to both tables, so a trace never outlives its hops or the reverse.
--
-- Text columns are sized so that no value the ingestor writes is wider than
-- its column: StarRocks filters such a row out of a Stream Load batch.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.mtr_traces (
  id VARCHAR(64) NOT NULL,
  `time` DATETIME NOT NULL,
  agent_id VARCHAR(256) NOT NULL,
  gateway_id VARCHAR(256),
  check_id VARCHAR(256),
  check_name VARCHAR(1024),
  device_id VARCHAR(256),
  target VARCHAR(1024) NOT NULL,
  target_ip VARCHAR(1024) NOT NULL,
  target_reached BOOLEAN NOT NULL,
  total_hops INT NOT NULL,
  probed_hops INT,
  last_responding_hop INT,
  protocol VARCHAR(32) NOT NULL,
  tcp_port INT,
  ip_version INT NOT NULL,
  packet_size INT,
  `partition` VARCHAR(128),
  error VARCHAR(65533),
  tcp_handshake_ttl INT,
  tcp_handshake_attempts INT,
  tcp_syn_sent INT,
  tcp_synack_received INT,
  tcp_rst_received INT,
  tcp_syn_unanswered INT,
  tcp_syn_drop_pct DOUBLE,
  tcp_syn_retransmits INT,
  tcp_answered_after_retx INT,
  tcp_ack_mismatch INT,
  tcp_synack_duplicates INT,
  tcp_handshake_rtt_min_us BIGINT,
  tcp_handshake_rtt_avg_us BIGINT,
  tcp_handshake_rtt_max_us BIGINT,
  tcp_server_response_us BIGINT,
  created_at DATETIME NOT NULL
)
PRIMARY KEY (id, `time`)
PARTITION BY date_trunc('day', `time`)
DISTRIBUTED BY HASH(id) BUCKETS 8
ORDER BY (`time`, id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "30"
);

CREATE TABLE IF NOT EXISTS serviceradar.mtr_hops (
  id VARCHAR(64) NOT NULL,
  `time` DATETIME NOT NULL,
  trace_id VARCHAR(64) NOT NULL,
  target_ip VARCHAR(1024),
  device_id VARCHAR(256),
  hop_number INT NOT NULL,
  addr VARCHAR(64),
  hostname VARCHAR(1024),
  ecmp_addrs ARRAY<VARCHAR(64)>,
  asn INT,
  asn_org VARCHAR(1024),
  mpls_labels JSON,
  sent INT NOT NULL,
  received INT NOT NULL,
  loss_pct DOUBLE NOT NULL,
  last_us BIGINT,
  avg_us BIGINT,
  min_us BIGINT,
  max_us BIGINT,
  stddev_us BIGINT,
  jitter_us BIGINT,
  jitter_worst_us BIGINT,
  jitter_interarrival_us BIGINT,
  unreachable_code INT,
  reply_time_exceeded INT,
  reply_unreachable INT,
  reply_synack INT,
  reply_rst INT,
  created_at DATETIME NOT NULL
)
PRIMARY KEY (id, `time`)
PARTITION BY date_trunc('day', `time`)
DISTRIBUTED BY HASH(id) BUCKETS 8
ORDER BY (`time`, trace_id, hop_number)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "30"
);
