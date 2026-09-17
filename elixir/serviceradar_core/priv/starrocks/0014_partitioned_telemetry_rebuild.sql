-- Rebuild for a warehouse created before daily partitioning.
--
-- 0001-0004 previously created these tables with PRIMARY KEY (id) and no
-- PARTITION BY. StarRocks can neither add partitioning to an existing table
-- nor change a primary key with ALTER, so the retention property those tables
-- now carry (`partition_live_number`) is rejected on them and the warehouse
-- grows without bound. The tables are recreated rather than retrofitted.
--
-- This is safe because StarRocks is a shadow copy while `cutoverDatasets` is
-- empty: CNPG stays authoritative, and EventWriter refills the warehouse from
-- JetStream as new telemetry arrives. Recover history with the bounded
-- newest-first CNPG backfill after the tables exist again. Do NOT run this on
-- a warehouse that already serves a cut-over dataset until that dataset has
-- been returned to CNPG.
--
-- Order matters: the hourly materialized views read the base tables, so they
-- are dropped first and rebuilt by re-applying 0005.
--
-- After this file:
--   1. re-apply 0001, 0002, 0003, 0004 (they now create partitioned tables)
--   2. re-apply 0005 (hourly materialized views)
--   3. backfill history, newest first, from CNPG
--
-- Do NOT replay 0006-0013. Every column they add is already declared in
-- 0001-0004, and re-running an ADD COLUMN fails once the column exists.
--
-- Skip this file entirely on a warehouse created from the partitioned DDL.

DROP MATERIALIZED VIEW IF EXISTS serviceradar.ocsf_network_activity_hourly;
DROP MATERIALIZED VIEW IF EXISTS serviceradar.timeseries_metrics_hourly;
DROP MATERIALIZED VIEW IF EXISTS serviceradar.events_hourly;

DROP TABLE IF EXISTS serviceradar.ocsf_network_activity;
DROP TABLE IF EXISTS serviceradar.timeseries_metrics;
DROP TABLE IF EXISTS serviceradar.logs;
DROP TABLE IF EXISTS serviceradar.events;
