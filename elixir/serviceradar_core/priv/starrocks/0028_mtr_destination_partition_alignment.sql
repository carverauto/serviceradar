-- Align MTR destination refresh dependencies with both base tables' event day.
-- Not an Ecto migration; BUILD.bazel in this directory owns the DDL contract.
--
-- EventWriter normalizes every hop to its trace's event time, including loads
-- received after midnight. Equal partition keys let StarRocks invalidate and
-- scan just that day. Rank within (event time, trace, hop position), preserving
-- the id tie-break without a second trace scan or a window spanning all days.
--
-- Rebuild only derived state. Defer the initial refresh to the 30-second
-- schedule and keep one partition per task; do not issue an unbounded manual
-- refresh. RollupFreshness routes missing or incomplete refreshes to raw data.
-- Changed historical partitions remain eligible for repair; no latest-only
-- refresh limit is set. Base tables and their retention are untouched.
DROP MATERIALIZED VIEW IF EXISTS serviceradar.mtr_destination_hourly;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.mtr_destination_hourly
PARTITION BY day
DISTRIBUTED BY HASH(bucket) BUCKETS 8
REFRESH DEFERRED MANUAL
PROPERTIES (
  "replication_num" = "3",
  "partition_refresh_number" = "1"
)
AS
SELECT
  date_trunc('day', t.`time`) AS day,
  date_trunc('hour', t.`time`) AS bucket,
  COUNT(t.`id`) AS path_count,
  COUNT(dh.trace_id) AS endpoint_sample_count,
  COUNT(CASE WHEN dh.sent > 0 THEN dh.trace_id END) AS loss_sample_count,
  COUNT(CASE WHEN dh.avg_us IS NOT NULL AND dh.received > 0 THEN dh.trace_id END) AS latency_sample_count,
  SUM(CASE WHEN dh.sent > 0 THEN dh.sent END) AS sent_total,
  SUM(CASE WHEN dh.sent > 0 THEN dh.received END) AS received_total,
  SUM(CASE WHEN dh.avg_us IS NOT NULL AND dh.received > 0 THEN CAST(dh.avg_us AS DOUBLE) * dh.received END) AS avg_us_weighted,
  SUM(CASE WHEN dh.avg_us IS NOT NULL AND dh.received > 0 THEN dh.received END) AS latency_weight,
  COUNT(CASE
    WHEN NOT t.target_reached
      OR (dh.sent > dh.received)
      OR (dh.avg_us IS NOT NULL AND dh.received > 0 AND dh.avg_us > 100000)
    THEN t.`id`
  END) AS degraded_count
FROM serviceradar.mtr_traces t
LEFT JOIN (
  SELECT `time`, trace_id, hop_number, sent, received, avg_us
  FROM (
    SELECT
      h.`time`,
      h.trace_id,
      h.hop_number,
      h.sent,
      h.received,
      h.avg_us,
      ROW_NUMBER() OVER (
        PARTITION BY h.`time`, h.trace_id, h.hop_number
        ORDER BY h.`id` DESC
      ) AS terminal_rank
    FROM serviceradar.mtr_hops h
  ) ranked_terminal_hops
  WHERE terminal_rank = 1
) dh ON dh.trace_id = t.`id`
  AND dh.`time` = t.`time`
  AND t.target_reached
  AND dh.hop_number = t.total_hops
GROUP BY date_trunc('day', t.`time`), date_trunc('hour', t.`time`);

-- Use the same ALTER path as 0027: CREATE validates against the FE's default
-- minimum interval, even when ALTER supports the existing 30-second cadence.
ALTER MATERIALIZED VIEW serviceradar.mtr_destination_hourly
REFRESH ASYNC EVERY (INTERVAL 30 SECOND);
