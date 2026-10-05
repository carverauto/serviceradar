-- Coalesce small base-table loads into a 30-second refresh cadence.
-- ALTER preserves existing partitions and avoids rebuilding retained history.
-- Changed partitions, including late data, remain eligible; do not cap the
-- history to the newest days. One partition per refresh subtask bounds initial
-- catch-up and midnight/late-data repair without a whole-history rebuild.
-- MTR destination retains its terminal-hop selection semantics. Its broad hop
-- invalidation still needs a separate engine-proven partition-pruning change.
ALTER MATERIALIZED VIEW serviceradar.ocsf_network_activity_hourly REFRESH ASYNC EVERY(INTERVAL 30 SECOND);
ALTER MATERIALIZED VIEW serviceradar.ocsf_network_activity_hourly SET ("partition_refresh_number" = "1");

ALTER MATERIALIZED VIEW serviceradar.timeseries_metrics_hourly REFRESH ASYNC EVERY(INTERVAL 30 SECOND);
ALTER MATERIALIZED VIEW serviceradar.timeseries_metrics_hourly SET ("partition_refresh_number" = "1");

ALTER MATERIALIZED VIEW serviceradar.events_hourly REFRESH ASYNC EVERY(INTERVAL 30 SECOND);
ALTER MATERIALIZED VIEW serviceradar.events_hourly SET ("partition_refresh_number" = "1");

ALTER MATERIALIZED VIEW serviceradar.traces_stats_5m REFRESH ASYNC EVERY(INTERVAL 30 SECOND);
ALTER MATERIALIZED VIEW serviceradar.traces_stats_5m SET ("partition_refresh_number" = "1");

ALTER MATERIALIZED VIEW serviceradar.spans_red_1h REFRESH ASYNC EVERY(INTERVAL 30 SECOND);
ALTER MATERIALIZED VIEW serviceradar.spans_red_1h SET ("partition_refresh_number" = "1");

ALTER MATERIALIZED VIEW serviceradar.mtr_hops_hourly REFRESH ASYNC EVERY(INTERVAL 30 SECOND);
ALTER MATERIALIZED VIEW serviceradar.mtr_hops_hourly SET ("partition_refresh_number" = "1");

ALTER MATERIALIZED VIEW serviceradar.mtr_destination_hourly REFRESH ASYNC EVERY(INTERVAL 30 SECOND);
ALTER MATERIALIZED VIEW serviceradar.mtr_destination_hourly SET ("partition_refresh_number" = "1");
