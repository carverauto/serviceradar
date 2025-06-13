-- Migration that preserves data using supported functions

-- Step 0: ensure the old stream exists (empty on brand-new clusters)
CREATE STREAM IF NOT EXISTS timeseries_metrics (
    poller_id   string,
    metric_name string,
    metric_type string,
    value       string,
    metadata    string,
    timestamp   DateTime64(3) DEFAULT now64(3)
);

-- Step 1: Create new stream with updated schema
CREATE STREAM IF NOT EXISTS timeseries_metrics_new (
    poller_id string,
    target_device_ip string,
    ifIndex int32,
    metric_name string,
    metric_type string,
    value string,
    metadata string,
    timestamp DateTime64(3) DEFAULT now64(3)
);

-- Step 2: Copy existing data with safe defaults
-- This only runs if the old stream exists
INSERT INTO timeseries_metrics_new
(poller_id, target_device_ip, ifIndex, metric_name, metric_type, value, metadata, timestamp)
SELECT
    poller_id,
    '' AS target_device_ip,  -- Default empty string
    0 AS ifIndex,           -- Default 0
    metric_name,
    metric_type,
    value,
    metadata,
    timestamp
FROM table(timeseries_metrics);

-- Step 3: Drop the old stream
DROP STREAM IF EXISTS timeseries_metrics;

-- Step 4: Rename new stream to final name
RENAME STREAM timeseries_metrics_new TO timeseries_metrics;