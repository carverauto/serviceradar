-- Populate unified_devices with existing agents and pollers as service devices

-- Insert existing pollers as service devices
INSERT INTO unified_devices (
    device_id, 
    ip, 
    poller_id, 
    hostname, 
    mac, 
    discovery_sources, 
    is_available, 
    first_seen, 
    last_seen, 
    metadata, 
    agent_id,
    device_type,
    service_type,
    service_status,
    last_heartbeat,
    os_info,
    version_info
)
SELECT 
    'service-poller-' || poller_id as device_id,
    COALESCE(ip, '127.0.0.1') as ip,
    poller_id,
    COALESCE(hostname, host()) as hostname,
    '' as mac,
    ['poller'] as discovery_sources,
    CASE 
        WHEN status = 'running' THEN true
        ELSE false
    END as is_available,
    created_at as first_seen,
    last_updated as last_seen,
    map('poller_status', status) as metadata,
    '' as agent_id,
    'service_device' as device_type,
    'poller' as service_type,
    CASE 
        WHEN status = 'running' THEN 'online'
        WHEN status = 'stopped' THEN 'offline'
        ELSE 'degraded'
    END as service_status,
    last_updated as last_heartbeat,
    'unknown' as os_info,
    'unknown' as version_info
FROM pollers
WHERE poller_id IS NOT NULL;

-- Insert agents based on unique agent_ids from various tables  
INSERT INTO unified_devices (
    device_id, 
    ip, 
    poller_id, 
    hostname, 
    mac, 
    discovery_sources, 
    is_available, 
    first_seen, 
    last_seen, 
    metadata, 
    agent_id,
    device_type,
    service_type,
    service_status,
    last_heartbeat,
    os_info,
    version_info
)
SELECT DISTINCT
    'service-agent-' || agent_id as device_id,
    '127.0.0.1' as ip,
    '' as poller_id,
    'unknown' as hostname,
    '' as mac,
    ['agent'] as discovery_sources,
    true as is_available,
    NOW() as first_seen,
    NOW() as last_seen,
    map() as metadata,
    agent_id,
    'service_device' as device_type,
    'agent' as service_type,
    'online' as service_status,
    NOW() as last_heartbeat,
    'unknown' as os_info,
    'unknown' as version_info
FROM (
    -- Get agent_ids from cpu_metrics
    SELECT agent_id FROM cpu_metrics WHERE agent_id IS NOT NULL AND agent_id != ''
    UNION
    -- Get agent_ids from disk_metrics  
    SELECT agent_id FROM disk_metrics WHERE agent_id IS NOT NULL AND agent_id != ''
    UNION
    -- Get agent_ids from memory_metrics
    SELECT agent_id FROM memory_metrics WHERE agent_id IS NOT NULL AND agent_id != ''
    UNION
    -- Get agent_ids from service_status
    SELECT agent_id FROM service_status WHERE agent_id IS NOT NULL AND agent_id != ''
) as agents
WHERE NOT EXISTS (
    SELECT 1 FROM unified_devices ud 
    WHERE ud.agent_id = agents.agent_id 
    AND ud.device_type = 'service_device'
);

-- Update pollers that also have agent functionality to be 'agent_poller' type
UPDATE unified_devices 
SET 
    service_type = 'agent_poller',
    device_id = 'service-agent-poller-' || poller_id,
    last_seen = NOW(),
    last_heartbeat = NOW()
WHERE device_type = 'service_device'
AND service_type = 'poller' 
AND poller_id IN (
    SELECT DISTINCT poller_id 
    FROM service_status 
    WHERE agent_id IS NOT NULL 
    AND agent_id != '' 
    AND poller_id IS NOT NULL 
    AND poller_id != ''
);

-- Remove standalone agent entries if they're now part of agent_poller entries
DELETE FROM unified_devices 
WHERE device_type = 'service_device'
AND service_type = 'agent' 
AND agent_id IN (
    SELECT agent_id 
    FROM unified_devices 
    WHERE device_type = 'service_device'
    AND service_type = 'agent_poller'
);