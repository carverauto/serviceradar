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
-- Text columns are sized so that no value the processor writes is wider than
-- its column: StarRocks filters such a row out of a Stream Load batch. The
-- two unbounded CNPG columns (`message`, `raw_data`) are truncated UTF-8-safely
-- by Rows.encode/2 to their column widths rather than dropped.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.bmp_routing_events (
  id VARCHAR(64) NOT NULL,
  `time` DATETIME NOT NULL,
  event_type VARCHAR(256) NOT NULL,
  severity_id INT,
  router_id VARCHAR(256),
  router_ip VARCHAR(64),
  peer_ip VARCHAR(64),
  peer_asn BIGINT,
  local_asn BIGINT,
  prefix VARCHAR(128),
  message VARCHAR(65533),
  metadata JSON,
  raw_data VARCHAR(65533),
  created_at DATETIME
)
PRIMARY KEY (id, `time`)
PARTITION BY date_trunc('day', `time`)
DISTRIBUTED BY HASH(id) BUCKETS 8
ORDER BY (`time`, id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "365"
);
