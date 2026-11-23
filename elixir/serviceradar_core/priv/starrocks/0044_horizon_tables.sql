-- Horizon telemetry tables (OpenSpec add-horizon-srql-entities).
-- StarRocks-only: EventWriter projects Horizon OCSF events directly to
-- serviceradar.horizon_outages, serviceradar.horizon_bgp_events, and
-- serviceradar.horizon_bgp_zombies; serviceradar.horizon_path_hops will be
-- populated by the horizon-probe Native Add-On.
--
-- All four tables use daily partitioning and StarRocks-managed retention via
-- partition_live_number (30 days for outages/BGP/zombies, 14 days for path hops).
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE TABLE IF NOT EXISTS serviceradar.horizon_outages (
  time DATETIME NOT NULL,
  outage_id VARCHAR(256) NOT NULL,
  status VARCHAR(64) NOT NULL,
  severity VARCHAR(64) NOT NULL,
  entity_type VARCHAR(64) NOT NULL,
  entity_key VARCHAR(256) NOT NULL,
  region VARCHAR(128),
  covering_prefix VARCHAR(128),
  origin_asn BIGINT,
  corroborating_pop_count INT NOT NULL,
  avg_forwarding_loss_pct DOUBLE,
  avg_synthetic_failure_pct DOUBLE,
  window_start_ms BIGINT,
  window_end_ms BIGINT,
  correlated_bgp_event_ids JSON,
  raw_data JSON
)
PRIMARY KEY (time, outage_id)
PARTITION BY date_trunc('day', time)
DISTRIBUTED BY HASH(outage_id) BUCKETS 4
ORDER BY (time, outage_id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "30"
);

CREATE TABLE IF NOT EXISTS serviceradar.horizon_bgp_events (
  time DATETIME NOT NULL,
  event_id VARCHAR(256) NOT NULL,
  kind VARCHAR(64) NOT NULL,
  level VARCHAR(64) NOT NULL,
  prefix VARCHAR(128) NOT NULL,
  origin_asn BIGINT,
  as_path JSON,
  rpki_status VARCHAR(64),
  caida_leak_inference VARCHAR(256),
  watchlist_id VARCHAR(256),
  client_label VARCHAR(256),
  raw_data JSON
)
PRIMARY KEY (time, event_id)
PARTITION BY date_trunc('day', time)
DISTRIBUTED BY HASH(event_id) BUCKETS 4
ORDER BY (time, event_id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "30"
);

CREATE TABLE IF NOT EXISTS serviceradar.horizon_bgp_zombies (
  time DATETIME NOT NULL,
  episode_id VARCHAR(256) NOT NULL,
  status VARCHAR(64) NOT NULL,
  prefix VARCHAR(128) NOT NULL,
  origin_asn BIGINT,
  divergence_pct DOUBLE,
  is_beacon BOOLEAN NOT NULL,
  withdrawn_peers INT,
  total_peers INT,
  stuck_peer_asns JSON,
  first_seen_at DATETIME,
  resolved_at DATETIME,
  raw_data JSON
)
PRIMARY KEY (time, episode_id)
PARTITION BY date_trunc('day', time)
DISTRIBUTED BY HASH(episode_id) BUCKETS 4
ORDER BY (time, episode_id)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "30"
);

CREATE TABLE IF NOT EXISTS serviceradar.horizon_path_hops (
  time DATETIME NOT NULL,
  round_id VARCHAR(256) NOT NULL,
  target_id VARCHAR(256) NOT NULL,
  pop_id VARCHAR(128) NOT NULL,
  hop_ttl INT NOT NULL,
  hop_ip VARCHAR(64),
  router_alias_id VARCHAR(256),
  alias_confidence DOUBLE,
  asn BIGINT,
  as_org VARCHAR(256),
  is_cloud BOOLEAN NOT NULL,
  cloud_provider VARCHAR(64),
  cloud_region VARCHAR(128),
  forwarding_loss_pct DOUBLE,
  avg_rtt_ms DOUBLE,
  effective_path_mtu INT,
  mtu_blackhole_detected BOOLEAN NOT NULL,
  blackhole_hop_ttl INT,
  raw_data JSON
)
PRIMARY KEY (time, round_id, target_id, pop_id, hop_ttl)
PARTITION BY date_trunc('day', time)
DISTRIBUTED BY HASH(target_id) BUCKETS 4
ORDER BY (target_id, time, round_id, pop_id, hop_ttl)
PROPERTIES (
  "replication_num" = "3",
  "enable_persistent_index" = "true",
  "partition_live_number" = "14"
);
