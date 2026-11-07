-- StarRocks primary-key table for BMP routing events.
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
--
-- Column names are those of platform.bmp_routing_events, so a reader can
-- serve either backend from the same row shape. EventWriter's
-- AnalyticsSignals processor writes BMP routing events here, and only here,
-- when StarRocks is enabled; otherwise it writes CNPG.
--
-- The key is (id, `time`), as for the other telemetry tables: StarRocks
-- requires the partition column in the primary key. `id` is the stable event
-- identity the processor derives from the message (`Ecto.UUID.dump!` of
-- `event_identity`), so a redelivered message upserts the rows it already
-- loaded.
--
-- `metadata` is the normalized causal envelope and is kept as a JSON document
-- (like mtr_hops.mpls_labels), so a reader decodes it exactly as CNPG's jsonb
-- hands it back.
--
-- partition_live_number is the one-year retention default;
-- SERVICERADAR_STARROCKS_RETENTION_DAYS_BMP is applied on top at boot.
--
-- Free-text columns (`event_type`, `message`, `raw_data`) are VARCHAR(1048576),
-- the 1 MiB shipped NATS max_payload, so values are stored whole rather than
-- cut. Protocol-bounded identifiers (`router_id`, `router_ip`, `peer_ip`,
-- `prefix`) keep their widths; Rows.encode/2 stores an over-wide identifier as
-- NULL rather than a truncated one.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.bmp_routing_events (
  id VARCHAR(64) NOT NULL,
  `time` DATETIME NOT NULL,
  event_type VARCHAR(1048576) NOT NULL,
  severity_id INT,
  router_id VARCHAR(256),
  router_ip VARCHAR(64),
  peer_ip VARCHAR(64),
  peer_asn BIGINT,
  local_asn BIGINT,
  prefix VARCHAR(128),
  message VARCHAR(1048576),
  metadata JSON,
  raw_data VARCHAR(1048576),
  created_at DATETIME
)
PRIMARY KEY (id, `time`)
PARTITION BY date_trunc('day', `time`)
DISTRIBUTED BY HASH(id) BUCKETS 1
ORDER BY (`time`, id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "365"
);
