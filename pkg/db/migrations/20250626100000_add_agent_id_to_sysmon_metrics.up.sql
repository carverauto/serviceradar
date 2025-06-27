-- Add agent_id field to sysmon metrics streams to support agent-level attribution
-- This complements the host_id field by providing the ServiceRadar agent identifier

-- Add agent_id to CPU metrics
CREATE STREAM IF NOT EXISTS cpu_metrics_with_agent_id (
    poller_id string,
    agent_id string,
    host_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    core_id int32,
    usage_percent float64
);

-- Migrate existing CPU metrics data (using empty string as default agent_id for historical data)
INSERT INTO cpu_metrics_with_agent_id (poller_id, agent_id, host_id, timestamp, core_id, usage_percent)
SELECT poller_id, '' as agent_id, host_id, timestamp, core_id, usage_percent 
FROM table(cpu_metrics);

-- Drop old CPU metrics stream and rename new one
DROP STREAM cpu_metrics;
RENAME STREAM cpu_metrics_with_agent_id TO cpu_metrics;

-- Add agent_id to disk metrics
CREATE STREAM IF NOT EXISTS disk_metrics_with_agent_id (
    poller_id string,
    agent_id string,
    host_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    mount_point string,
    used_bytes uint64,
    total_bytes uint64
);

-- Migrate existing disk metrics data
INSERT INTO disk_metrics_with_agent_id (poller_id, agent_id, host_id, timestamp, mount_point, used_bytes, total_bytes)
SELECT poller_id, '' as agent_id, host_id, timestamp, mount_point, used_bytes, total_bytes 
FROM table(disk_metrics);

-- Drop old disk metrics stream and rename new one
DROP STREAM disk_metrics;
RENAME STREAM disk_metrics_with_agent_id TO disk_metrics;

-- Add agent_id to memory metrics
CREATE STREAM IF NOT EXISTS memory_metrics_with_agent_id (
    poller_id string,
    agent_id string,
    host_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    used_bytes uint64,
    total_bytes uint64
);

-- Migrate existing memory metrics data
INSERT INTO memory_metrics_with_agent_id (poller_id, agent_id, host_id, timestamp, used_bytes, total_bytes)
SELECT poller_id, '' as agent_id, host_id, timestamp, used_bytes, total_bytes 
FROM table(memory_metrics);

-- Drop old memory metrics stream and rename new one
DROP STREAM memory_metrics;
RENAME STREAM memory_metrics_with_agent_id TO memory_metrics;