-- Foundational migration to create all necessary streams, replacing the old initSchema function.

-- Metrics Streams
CREATE STREAM IF NOT EXISTS cpu_metrics (
    poller_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    core_id int32,
    usage_percent float64
);

CREATE STREAM IF NOT EXISTS disk_metrics (
    poller_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    mount_point string,
    used_bytes uint64,
    total_bytes uint64
);

CREATE STREAM IF NOT EXISTS memory_metrics (
    poller_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    used_bytes uint64,
    total_bytes uint64
);

-- Poller Streams
CREATE STREAM IF NOT EXISTS pollers (
    poller_id string,
    first_seen DateTime64(3) DEFAULT now64(3),
    last_seen DateTime64(3) DEFAULT now64(3),
    is_healthy bool
);

CREATE STREAM IF NOT EXISTS poller_history (
    poller_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    is_healthy bool
);

-- Service & Auth Streams
CREATE STREAM IF NOT EXISTS service_status (
    poller_id string,
    service_name string,
    service_type string,
    available bool,
    details string,
    timestamp DateTime64(3) DEFAULT now64(3),
    agent_id string
);

CREATE STREAM IF NOT EXISTS users (
    id string,
    email string,
    name string,
    provider string,
    created_at DateTime64(3) DEFAULT now64(3),
    updated_at DateTime64(3) DEFAULT now64(3)
);

-- Discovery Streams
CREATE STREAM IF NOT EXISTS discovered_interfaces (
    timestamp DateTime64(3) DEFAULT now64(3),
    agent_id string,
    poller_id string,
    device_ip string,
    device_id string,
    ifIndex int32,
    ifName nullable(string),
    ifDescr nullable(string),
    ifAlias nullable(string),
    ifSpeed uint64,
    ifPhysAddress nullable(string),
    ip_addresses array(string),
    ifAdminStatus int32,
    ifOperStatus int32,
    metadata map(string, string)
);

CREATE STREAM IF NOT EXISTS topology_discovery_events (
    timestamp DateTime64(3) DEFAULT now64(3),
    agent_id string,
    poller_id string,
    local_device_ip string,
    local_device_id string,
    local_ifIndex int32,
    local_ifName nullable(string),
    protocol_type string,
    neighbor_chassis_id nullable(string),
    neighbor_port_id nullable(string),
    neighbor_port_descr nullable(string),
    neighbor_system_name nullable(string),
    neighbor_management_address nullable(string),
    neighbor_bgp_router_id nullable(string),
    neighbor_ip_address nullable(string),
    neighbor_as nullable(uint32),
    bgp_session_state nullable(string),
    metadata map(string, string)
);

-- Note: The timeseries_metrics stream is created by a later migration (20250612...),
-- so it is intentionally omitted here to allow that migration to run correctly.