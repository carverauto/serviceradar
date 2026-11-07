-- Right-size the bucket count of the day-partitioned telemetry tables.
--
-- 0001-0004 gave logs, events, flows and metrics 16 buckets per day and the
-- MTR, OTel and BMP tables 8. On a measured deployment those tablets held
-- 0.5-19 MB each (StarRocks sizes a tablet in gigabytes), about 8,300 tablets
-- for about 50 GB, and every tablet carries metadata on every compute node and
-- one more file per load. The new counts keep a day of each table in a few
-- tablets: logs, events and flows 2, metrics 4, MTR hops and OTel traces 2,
-- MTR traces, OTel metrics and BMP events 1. The CREATEs carry the same counts
-- for fresh installs, where every statement below finds nothing to change.
--
-- Two statements per table, both safe while EventWriter keeps loading:
--
--   * `DISTRIBUTED BY ... DEFAULT BUCKETS n` changes only the count new day
--     partitions are created with. It is metadata, takes effect at once, and
--     rewrites nothing.
--   * `DISTRIBUTED BY ... BUCKETS n` is StarRocks' optimize job: it rewrites
--     the existing partitions into n buckets through temporary partitions,
--     online, while loads continue. A partition loaded during the job (today's,
--     or a late day) keeps its old layout rather than failing the job or a
--     load; it ages out with retention. SchemaMigrator skips the statement when
--     every partition already has n buckets, waits for any optimize job already
--     on the table, and waits for its own to reach FINISHED (CANCELLED fails
--     the migration, which is then retried) before the next statement.
--
-- The default is set first so day partitions created while the rewrite runs
-- already use the new count. The largest table goes last. The rollups are
-- rebuilt by 0040, after this, so their backfill reads rewritten partitions.
ALTER TABLE serviceradar.bmp_routing_events DISTRIBUTED BY HASH(id) DEFAULT BUCKETS 1;
ALTER TABLE serviceradar.bmp_routing_events DISTRIBUTED BY HASH(id) BUCKETS 1;

ALTER TABLE serviceradar.otel_metric_points DISTRIBUTED BY HASH(id) DEFAULT BUCKETS 1;
ALTER TABLE serviceradar.otel_metric_points DISTRIBUTED BY HASH(id) BUCKETS 1;

ALTER TABLE serviceradar.otel_metrics DISTRIBUTED BY HASH(id) DEFAULT BUCKETS 1;
ALTER TABLE serviceradar.otel_metrics DISTRIBUTED BY HASH(id) BUCKETS 1;

ALTER TABLE serviceradar.otel_traces DISTRIBUTED BY HASH(trace_id) DEFAULT BUCKETS 2;
ALTER TABLE serviceradar.otel_traces DISTRIBUTED BY HASH(trace_id) BUCKETS 2;

ALTER TABLE serviceradar.mtr_traces DISTRIBUTED BY HASH(id) DEFAULT BUCKETS 1;
ALTER TABLE serviceradar.mtr_traces DISTRIBUTED BY HASH(id) BUCKETS 1;

ALTER TABLE serviceradar.mtr_hops DISTRIBUTED BY HASH(id) DEFAULT BUCKETS 2;
ALTER TABLE serviceradar.mtr_hops DISTRIBUTED BY HASH(id) BUCKETS 2;

ALTER TABLE serviceradar.ocsf_network_activity DISTRIBUTED BY HASH(id) DEFAULT BUCKETS 2;
ALTER TABLE serviceradar.ocsf_network_activity DISTRIBUTED BY HASH(id) BUCKETS 2;

ALTER TABLE serviceradar.events DISTRIBUTED BY HASH(id) DEFAULT BUCKETS 2;
ALTER TABLE serviceradar.events DISTRIBUTED BY HASH(id) BUCKETS 2;

ALTER TABLE serviceradar.logs DISTRIBUTED BY HASH(id) DEFAULT BUCKETS 2;
ALTER TABLE serviceradar.logs DISTRIBUTED BY HASH(id) BUCKETS 2;

ALTER TABLE serviceradar.timeseries_metrics DISTRIBUTED BY HASH(series_key) DEFAULT BUCKETS 4;
ALTER TABLE serviceradar.timeseries_metrics DISTRIBUTED BY HASH(series_key) BUCKETS 4;
