-- Track write-flood table growth after anomaly/capacity/flow fixes.
--
-- Usage:
--   psql "$DATABASE_URL" -f scripts/db/write_flood_growth.sql
--
-- The query is intentionally read-only and returns a point-in-time snapshot that
-- can be run by cron, Grafana, or psql. Compare rows_per_hour and table_bytes
-- before and after the F1/F12/F17/F39 fixes land.

WITH params AS (
  SELECT
    now() AS observed_at,
    INTERVAL '1 hour' AS short_window,
    INTERVAL '24 hours' AS long_window
),
targets AS (
  SELECT
    'ocsf_events'::text AS target,
    'F1/F12/F17 finding flood'::text AS fix_scope,
    'platform.ocsf_events'::regclass AS relation_oid,
    (SELECT COUNT(*) FROM platform.ocsf_events e, params p WHERE e.time >= p.observed_at - p.short_window)::numeric AS rows_1h,
    (SELECT COUNT(*) FROM platform.ocsf_events e, params p WHERE e.time >= p.observed_at - p.long_window)::numeric AS rows_24h,
    (SELECT COUNT(*) FROM platform.ocsf_events e, params p WHERE e.created_at >= p.observed_at - p.short_window)::numeric AS ingested_1h,
    NULL::numeric AS logical_volume_1h

  UNION ALL

  SELECT
    'capacity_forecasts'::text AS target,
    'F12 capacity idempotency'::text AS fix_scope,
    'platform.capacity_forecasts'::regclass AS relation_oid,
    (SELECT COUNT(*) FROM platform.capacity_forecasts c, params p WHERE c.forecasted_at >= p.observed_at - p.short_window)::numeric AS rows_1h,
    (SELECT COUNT(*) FROM platform.capacity_forecasts c, params p WHERE c.forecasted_at >= p.observed_at - p.long_window)::numeric AS rows_24h,
    (SELECT COUNT(*) FROM platform.capacity_forecasts c, params p WHERE c.inserted_at >= p.observed_at - p.short_window)::numeric AS ingested_1h,
    (SELECT COUNT(*) FROM platform.capacity_forecasts c, params p WHERE c.status = 'projected' AND c.forecasted_at >= p.observed_at - p.short_window)::numeric AS logical_volume_1h

  UNION ALL

  SELECT
    'ocsf_network_activity'::text AS target,
    'F39 sampled flow scaling'::text AS fix_scope,
    'platform.ocsf_network_activity'::regclass AS relation_oid,
    (SELECT COUNT(*) FROM platform.ocsf_network_activity f, params p WHERE f.time >= p.observed_at - p.short_window)::numeric AS rows_1h,
    (SELECT COUNT(*) FROM platform.ocsf_network_activity f, params p WHERE f.time >= p.observed_at - p.long_window)::numeric AS rows_24h,
    (SELECT COUNT(*) FROM platform.ocsf_network_activity f, params p WHERE f.created_at >= p.observed_at - p.short_window)::numeric AS ingested_1h,
    (
      SELECT COALESCE(SUM(COALESCE(f.bytes_total, 0)::numeric * GREATEST(COALESCE(f.sampling_rate, 1), 1)), 0)
      FROM platform.ocsf_network_activity f, params p
      WHERE f.time >= p.observed_at - p.short_window
    ) AS logical_volume_1h
)
SELECT
  p.observed_at,
  t.target,
  t.fix_scope,
  t.rows_1h,
  round(t.rows_1h / EXTRACT(EPOCH FROM p.short_window) * 3600, 2) AS rows_per_hour_1h,
  t.rows_24h,
  round(t.rows_24h / EXTRACT(EPOCH FROM p.long_window) * 3600, 2) AS rows_per_hour_24h,
  t.ingested_1h,
  t.logical_volume_1h,
  pg_total_relation_size(t.relation_oid) AS table_bytes,
  pg_size_pretty(pg_total_relation_size(t.relation_oid)) AS table_size
FROM targets t
CROSS JOIN params p
ORDER BY t.target;
