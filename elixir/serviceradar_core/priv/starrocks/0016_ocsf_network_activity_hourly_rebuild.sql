-- Rebuild for a warehouse whose flow rollup predates sampling-weighted totals.
-- 0005 is CREATE ... IF NOT EXISTS, so it cannot correct an MV that already
-- exists. The previous definition summed bytes_in/bytes_out only, which
-- under-counts every row that carries bytes_total with NULL directional halves
-- and ignores sampling_rate entirely, so a chart served from it disagreed with
-- the same chart served from the raw table.
--
-- Safe to run at any time: the MV is derived state, and StarRocks refreshes it
-- from ocsf_network_activity after creation.
DROP MATERIALIZED VIEW IF EXISTS serviceradar.ocsf_network_activity_hourly;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.ocsf_network_activity_hourly
DISTRIBUTED BY HASH(bucket) BUCKETS 8
REFRESH ASYNC
PROPERTIES (
  "replication_num" = "3"
)
AS
SELECT
  date_trunc('hour', `time`) AS bucket,
  SUM(COALESCE(bytes_total, COALESCE(bytes_in, 0) + COALESCE(bytes_out, 0)) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS bytes_total,
  SUM(COALESCE(packets_total, COALESCE(packets_in, 0) + COALESCE(packets_out, 0)) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS packets_total,
  SUM(COALESCE(bytes_in, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS bytes_in,
  SUM(COALESCE(bytes_out, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS bytes_out,
  SUM(COALESCE(packets_in, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS packets_in,
  SUM(COALESCE(packets_out, 0) * GREATEST(COALESCE(sampling_rate, 1), 1)) AS packets_out,
  COUNT(*) AS flow_count
FROM serviceradar.ocsf_network_activity
GROUP BY date_trunc('hour', `time`);
