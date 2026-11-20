-- RUM beacons telemetry table (OpenSpec add-web-property-inventory-and-boomerang-rum).
-- Column names match platform.rum_beacons in CNPG so EventWriter's RumBeacons
-- processor and dual-dialect SRQL readers share the exact same row shape.
--
-- Primary key is (web_property_id, observed_at, beacon_id) so StarRocks
-- deduplicates redelivered JetStream messages and keeps the partition key
-- observed_at in the key. partition_live_number = 30 defaults to 30 days.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.rum_beacons (
  web_property_id VARCHAR(64) NOT NULL,
  observed_at DATETIME NOT NULL,
  beacon_id VARCHAR(64) NOT NULL,
  canonical_origin VARCHAR(512),
  environment VARCHAR(64),
  url VARCHAR(4096),
  host VARCHAR(256),
  path VARCHAR(2048),
  metric_path VARCHAR(1024),
  referrer VARCHAR(4096),
  page_group VARCHAR(1024),
  initiator VARCHAR(128),
  trace_id VARCHAR(64),
  span_id VARCHAR(64),
  session_id VARCHAR(128),
  user_agent VARCHAR(1024),
  device_type VARCHAR(64),
  browser VARCHAR(128),
  os VARCHAR(128),
  lcp_ms DOUBLE,
  inp_ms DOUBLE,
  cls DOUBLE,
  fcp_ms DOUBLE,
  ttfb_ms DOUBLE,
  page_load_ms DOUBLE,
  dns_ms DOUBLE,
  connect_ms DOUBLE,
  tls_ms DOUBLE,
  dom_ready_ms DOUBLE,
  rage_clicks INT NOT NULL,
  js_errors INT NOT NULL,
  http_status INT NOT NULL,
  has_error BOOLEAN NOT NULL,
  cdn_provider VARCHAR(64),
  cdn_cache_status VARCHAR(64),
  cdn_edge_rtt_ms DOUBLE,
  cdn_origin_rtt_ms DOUBLE,
  cdn_pop VARCHAR(128),
  server_timing_raw VARCHAR(1024),
  client_ip VARCHAR(64),
  client_ip_anonymized BOOLEAN NOT NULL,
  country VARCHAR(16),
  region VARCHAR(64),
  city VARCHAR(128),
  asn INT,
  as_org VARCHAR(256),
  prefix_tag VARCHAR(256),
  attributes JSON,
  created_at DATETIME NOT NULL
)
PRIMARY KEY (web_property_id, observed_at, beacon_id)
PARTITION BY date_trunc('day', observed_at)
DISTRIBUTED BY HASH(web_property_id) BUCKETS 4
ORDER BY (web_property_id, observed_at, beacon_id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "30"
);
