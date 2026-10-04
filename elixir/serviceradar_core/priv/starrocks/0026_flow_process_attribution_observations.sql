-- StarRocks table for netprobe process attribution observations.
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
--
-- Core publishes each admitted FlowAttributionEvent batch on JetStream subject
-- flows.attribution.observations and EventWriter's FlowAttributionObservations
-- processor Stream-Loads the rows here. Nothing else writes the table and
-- nothing updates or deletes a row: the same socket observed twice is two rows,
-- and the correlator picks the newest qualifying one. That is why this is a
-- Duplicate Key table and not a Primary Key one -- an upsert per observation
-- would rewrite the same key thousands of times an hour, which is the churn
-- this table replaces.
--
-- Rows expire by whole daily partitions (partition_live_number). The value
-- below is the attribution dataset default; Retention applies the configured
-- value on top at boot. The correlator only reads the last
-- window-plus-skew (30 minutes), so it prunes to the newest one or two
-- partitions.
--
-- Text columns are sized so that no value the publisher writes is wider than
-- its column: StarRocks filters such a row out of a Stream Load batch. Rows
-- truncates comm, cmdline and workload_identity to these widths.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.flow_process_attribution_observations (
  observed_at DATETIME NOT NULL,
  `partition` VARCHAR(128) NOT NULL,
  proto INT NOT NULL,
  local_ip VARCHAR(64) NOT NULL,
  local_port INT NOT NULL,
  remote_ip VARCHAR(64) NOT NULL,
  remote_port INT NOT NULL,
  agent_id VARCHAR(256),
  attribution_key VARCHAR(64) NOT NULL,
  pid INT,
  comm VARCHAR(256),
  cmdline VARCHAR(65533),
  uid BIGINT,
  container_id VARCHAR(256),
  workload_identity VARCHAR(1048576)
)
DUPLICATE KEY (observed_at, `partition`, proto, local_ip)
PARTITION BY date_trunc('day', observed_at)
DISTRIBUTED BY HASH(`partition`, local_ip) BUCKETS 8
PROPERTIES (
  "replication_num" = "3",
  "partition_live_number" = "30"
);
