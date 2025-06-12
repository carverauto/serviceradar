-- Create a new stream with the updated 8-column schema.
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

-- Copy data from the old stream to the new one, populating new fields with default values.
-- This query assumes the old table exists and may need error handling if it doesn't.
INSERT INTO timeseries_metrics_new
    (poller_id, target_device_ip, ifIndex, metric_name, metric_type, value, metadata, timestamp)
SELECT
    poller_id,
    '' AS target_device_ip,
    0 AS ifIndex,
    metric_name,
    metric_type,
    value,
    metadata,
    timestamp
FROM timeseries_metrics;

-- Drop the old stream.
DROP STREAM timeseries_metrics;

-- Rename the new stream to the original name.
RENAME STREAM timeseries_metrics_new TO timeseries_metrics;
