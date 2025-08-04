-- =================================================================
-- == ROLLBACK MISSING OPERATIONAL STREAMS
-- =================================================================

-- Drop materialized views first
DROP VIEW IF EXISTS unified_device_pipeline_mv;

-- Drop all the operational streams we added
DROP STREAM IF EXISTS users;
DROP STREAM IF EXISTS rperf_metrics;
DROP STREAM IF EXISTS netflow_metrics;
DROP STREAM IF EXISTS events;
DROP STREAM IF EXISTS poller_statuses;
DROP STREAM IF EXISTS poller_history;
DROP STREAM IF EXISTS service_status;
DROP STREAM IF EXISTS service_statuses;
DROP STREAM IF EXISTS memory_metrics;
DROP STREAM IF EXISTS disk_metrics;
DROP STREAM IF EXISTS cpu_metrics;
DROP STREAM IF EXISTS timeseries_metrics;
DROP STREAM IF EXISTS topology_discovery_events;
DROP STREAM IF EXISTS discovered_interfaces;
DROP STREAM IF EXISTS unified_devices_registry;
DROP STREAM IF EXISTS unified_devices;
DROP STREAM IF EXISTS device_updates;
DROP STREAM IF EXISTS sweep_host_states;

-- Note: We recreated pollers, so we don't drop it here since it's needed