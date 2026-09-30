-- Day-partitioned hop rollups for the MTR panels and the dashboard card.
-- Not a Mix/Postgres migration; BUILD.bazel here says how these are applied.
--
-- mtr_hops_hourly aggregates every hop at (hour, target, device, address,
-- hop position), storing exactly the quantities the readers re-aggregate:
-- the probe totals loss_ratio(sent, received) is a ratio of, and the
-- received-weighted sums wavg(value, received) is a ratio of. A reader that
-- sums the stored columns over any set of hours reproduces the raw formula's
-- answer for the same widened window, so loss is never a mean of per-trace
-- percentages and latency is never a plain AVG.
--
-- asn and asn_org are deliberately absent. They come from GeoLite2 only and
-- are NULL for every internal hop and private AS, so grouping by them is a
-- partial view that must not be presented as fleet-wide; the StarRocks
-- dialect answers an asn-shaped query from the raw table, where the reader
-- sees the NULL groups it is filtering past (the shipped panel filters
-- asn:>0 itself). addr may be NULL -- a hop that never replied -- and that
-- group is kept, as the raw GROUP BY keeps it.
--
-- mtr_destination_hourly aggregates the dashboard card and sparklines:
-- one row per hour over the traces of that hour LEFT JOIN their reached
-- trace's terminal hop (hop_number = total_hops), the same join
-- MtrWarehouse's raw queries compute. Every count the card shows is
-- evaluated per trace inside the view -- degraded_count folds NOT reached,
-- destination loss and slow latency with the card's own OR -- so summing
-- stored columns over hours is the card's answer for the same widened
-- window.
--
-- Both views are partitioned by day in step with mtr_hops / mtr_traces
-- (see 0017 for why `day` sits beside `bucket`). mtr_destination_hourly
-- joins two tables partitioned identically and joined at trace time, so its
-- `day` derives from the trace side. Safe to run at any time: a rollup is
-- derived state, StarRocks refills it after creation, and RollupFreshness
-- answers from the raw table until it has.
CREATE DATABASE IF NOT EXISTS serviceradar;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.mtr_hops_hourly
PARTITION BY day
DISTRIBUTED BY HASH(addr) BUCKETS 8
REFRESH ASYNC
PROPERTIES (
  "replication_num" = "3"
)
AS
SELECT
  date_trunc('day', `time`) AS day,
  date_trunc('hour', `time`) AS bucket,
  target_ip,
  device_id,
  addr,
  hop_number,
  SUM(sent) AS sent_total,
  SUM(COALESCE(received, 0)) AS received_total,
  SUM(CAST(avg_us AS DOUBLE) * CAST(COALESCE(received, 0) AS DOUBLE)) AS avg_us_weighted,
  SUM(CAST(min_us AS DOUBLE) * CAST(COALESCE(received, 0) AS DOUBLE)) AS min_us_weighted,
  SUM(CAST(max_us AS DOUBLE) * CAST(COALESCE(received, 0) AS DOUBLE)) AS max_us_weighted,
  SUM(CAST(jitter_us AS DOUBLE) * CAST(COALESCE(received, 0) AS DOUBLE)) AS jitter_us_weighted,
  COUNT(*) AS hop_count
FROM serviceradar.mtr_hops
GROUP BY date_trunc('day', `time`), date_trunc('hour', `time`), target_ip, device_id, addr, hop_number;

CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.mtr_destination_hourly
PARTITION BY day
DISTRIBUTED BY HASH(bucket) BUCKETS 8
REFRESH ASYNC
PROPERTIES (
  "replication_num" = "3"
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
  SELECT trace_id, sent, received, avg_us
  FROM (
    SELECT
      h.trace_id,
      h.sent,
      h.received,
      h.avg_us,
      ROW_NUMBER() OVER (
        PARTITION BY h.trace_id
        ORDER BY h.`time` DESC, h.`id` DESC
      ) AS terminal_rank
    FROM serviceradar.mtr_traces tt
    INNER JOIN serviceradar.mtr_hops h
      ON h.trace_id = tt.`id`
      AND tt.target_reached
      AND h.hop_number = tt.total_hops
      AND h.`time` >= tt.`time`
  ) ranked_terminal_hops
  WHERE terminal_rank = 1
) dh ON dh.trace_id = t.`id`
GROUP BY date_trunc('day', t.`time`), date_trunc('hour', t.`time`);
