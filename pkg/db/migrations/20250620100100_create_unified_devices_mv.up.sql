-- This migration file should be updated to contain the following logic

-- Drop the previous, simple materialized view if it exists
DROP VIEW IF EXISTS sweep_to_unified_mv;

-- Create a new, smarter materialized view for sweep results
CREATE MATERIALIZED VIEW IF NOT EXISTS sweep_to_unified_mv INTO unified_devices AS
SELECT
    -- The key for the join
    s.device_id,

    -- Take the latest IP, agent, and poller from the sweep result
    s.ip,
    s.agent_id,
    s.poller_id,

    --  ****** THE FIX IS HERE ******
    -- Prioritize existing hostname; only use sweep's hostname if the existing one is null.
    COALESCE(d.hostname, s.hostname) AS hostname,

    -- Prioritize existing MAC address.
    COALESCE(d.mac, s.mac) AS mac,

    -- If the device already exists, preserve its original discovery source.
    -- Otherwise, set it to 'sweep'.
    COALESCE(d.discovery_source, s.discovery_source) as discovery_source,

    -- Always update availability from the sweep, as this is its primary purpose.
    s.is_available,

    -- Preserve the original first_seen time, but update last_seen.
    d.first_seen,
    s.last_seen,

    -- Prioritize existing metadata. Only use the sweep's metadata if none exists.
    COALESCE(d.metadata, s.metadata) as metadata,

    -- Provide the version column for the 'unified_devices' versioned_kv stream
    s._tp_time

FROM
    -- s is the new sweep result
    (SELECT *, concat(ip, ':', agent_id, ':', poller_id) as device_id, timestamp as _tp_time FROM sweep_results) AS s
        LEFT JOIN
    -- d is the device's current state in our destination table
        unified_devices AS d
    ON
        s.device_id = d.device_id;