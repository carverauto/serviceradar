CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.horizon_isp_accountability_mv
PARTITION BY day
DISTRIBUTED BY HASH(target_id) BUCKETS 1
REFRESH DEFERRED MANUAL
PROPERTIES (
  "replication_num" = "3",
  "partition_refresh_number" = "1"
)
AS
SELECT
  date_trunc('day', h.`time`) AS day,
  date_trunc('hour', h.`time`) AS bucket_hour,
  COALESCE(h.asn, 0) AS asn,
  COALESCE(h.as_org, '') AS as_org,
  h.target_id,
  COALESCE(AVG(h.forwarding_loss_pct), 0.0) AS forwarding_loss_pct,
  AVG(h.avg_rtt_ms) AS avg_rtt_ms,
  MAX(h.avg_rtt_ms) AS max_rtt_ms,
  SUM(CASE WHEN h.mtu_blackhole_detected THEN 1 ELSE 0 END) AS mtu_blackhole_count,
  MIN(CASE WHEN h.effective_path_mtu > 0 THEN h.effective_path_mtu END) AS min_effective_mtu,
  COALESCE(MAX(o.active_outage_count), 0) AS active_outage_count,
  COALESCE(MAX(b.bgp_anomaly_count), 0) AS bgp_anomaly_count,
  COALESCE(MAX(z.bgp_zombie_count), 0) AS bgp_zombie_count,
  CASE
    WHEN COALESCE(MAX(b.bgp_hijack_count), 0) > 0 THEN 'bgp_hijack'
    WHEN COALESCE(MAX(b.bgp_leak_count), 0) > 0 THEN 'bgp_route_leak'
    WHEN COALESCE(MAX(b.bgp_anomaly_count), 0) > 0 THEN 'bgp_anomaly'
    WHEN COALESCE(MAX(z.bgp_zombie_count), 0) > 0 THEN 'bgp_zombie'
    WHEN COALESCE(MAX(o.active_outage_count), 0) > 0 THEN 'active_outage'
    WHEN SUM(CASE WHEN h.mtu_blackhole_detected THEN 1 ELSE 0 END) > 0 THEN 'pmtud_blackhole'
    WHEN COALESCE(AVG(h.forwarding_loss_pct), 0.0) >= 1.0 AND COALESCE(h.asn, 0) = 0 THEN 'customer_lan'
    WHEN COALESCE(AVG(h.forwarding_loss_pct), 0.0) >= 1.0 THEN 'isp_transit'
    ELSE 'healthy'
  END AS first_blame_tier,
  COUNT(*) AS sample_count
FROM serviceradar.horizon_path_hops h
LEFT JOIN (
  SELECT
    date_trunc('day', `time`) AS day,
    date_trunc('hour', `time`) AS bucket_hour,
    origin_asn,
    COUNT(DISTINCT CASE WHEN LOWER(status) NOT IN ('resolved', 'cleared') THEN outage_id END) AS active_outage_count
  FROM serviceradar.horizon_outages
  WHERE origin_asn IS NOT NULL AND origin_asn > 0
  GROUP BY date_trunc('day', `time`), date_trunc('hour', `time`), origin_asn
) o ON o.day = date_trunc('day', h.`time`)
   AND o.bucket_hour = date_trunc('hour', h.`time`)
   AND o.origin_asn = h.asn
LEFT JOIN (
  SELECT
    date_trunc('day', `time`) AS day,
    date_trunc('hour', `time`) AS bucket_hour,
    origin_asn,
    COUNT(DISTINCT event_id) AS bgp_anomaly_count,
    COUNT(DISTINCT CASE
      WHEN LOWER(kind) = 'hijack' OR LOWER(COALESCE(rpki_status, '')) LIKE 'invalid%'
      THEN event_id
    END) AS bgp_hijack_count,
    COUNT(DISTINCT CASE
      WHEN LOWER(kind) LIKE '%leak%'
        OR LOWER(COALESCE(caida_leak_inference, '')) IN ('valley_free_violation', 'aspa_authoritative_invalid')
      THEN event_id
    END) AS bgp_leak_count
  FROM serviceradar.horizon_bgp_events
  WHERE origin_asn IS NOT NULL AND origin_asn > 0
  GROUP BY date_trunc('day', `time`), date_trunc('hour', `time`), origin_asn
) b ON b.day = date_trunc('day', h.`time`)
   AND b.bucket_hour = date_trunc('hour', h.`time`)
   AND b.origin_asn = h.asn
LEFT JOIN (
  SELECT
    date_trunc('day', `time`) AS day,
    date_trunc('hour', `time`) AS bucket_hour,
    origin_asn,
    COUNT(DISTINCT CASE WHEN LOWER(status) NOT IN ('resolved', 'cleared') THEN episode_id END) AS bgp_zombie_count
  FROM serviceradar.horizon_bgp_zombies
  WHERE origin_asn IS NOT NULL AND origin_asn > 0
  GROUP BY date_trunc('day', `time`), date_trunc('hour', `time`), origin_asn
) z ON z.day = date_trunc('day', h.`time`)
   AND z.bucket_hour = date_trunc('hour', h.`time`)
   AND z.origin_asn = h.asn
GROUP BY
  date_trunc('day', h.`time`),
  date_trunc('hour', h.`time`),
  COALESCE(h.asn, 0),
  COALESCE(h.as_org, ''),
  h.target_id;

ALTER MATERIALIZED VIEW serviceradar.horizon_isp_accountability_mv REFRESH ASYNC EVERY(INTERVAL 1 MINUTE);
