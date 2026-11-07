-- Refresh each rollup on a cadence matched to its bucket width instead of
-- every 30 seconds (0027).
--
-- A refresh is partition-scoped (one day partition per subtask, 0027), but it
-- still rewrites that whole day partition from the whole base day: at 30
-- seconds every view rewrote today's partition about 2,880 times a day, and
-- each rewrite creates new tablets and tablet metadata versions on every
-- compute node. An hourly bucket is not more correct for being rewritten
-- every 30 seconds; only its newest, still-filling bucket changes.
--
-- Hourly views refresh every 5 minutes, so the newest hour can trail its base
-- table by at most one cadence plus the refresh time, a twelfth of the bucket.
-- The 5-minute trace stats view refreshes every minute, a fifth of its bucket.
-- Earlier, complete buckets are unchanged by the cadence.
--
-- RollupFreshness accepts a refresh as recent within its view's cadence plus
-- 90 seconds of execution slack, and its table of cadences must match this
-- file (rollup_freshness_test.exs checks it). A stale view is read from its raw
-- table, never served short.
--
-- ALTER keeps existing partitions and the one-partition-per-subtask bound.
ALTER MATERIALIZED VIEW serviceradar.ocsf_network_activity_hourly REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);
ALTER MATERIALIZED VIEW serviceradar.timeseries_metrics_hourly REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);
ALTER MATERIALIZED VIEW serviceradar.events_hourly REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);
ALTER MATERIALIZED VIEW serviceradar.spans_red_1h REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);
ALTER MATERIALIZED VIEW serviceradar.mtr_hops_hourly REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);
ALTER MATERIALIZED VIEW serviceradar.mtr_destination_hourly REFRESH ASYNC EVERY(INTERVAL 5 MINUTE);
ALTER MATERIALIZED VIEW serviceradar.traces_stats_5m REFRESH ASYNC EVERY(INTERVAL 1 MINUTE);
