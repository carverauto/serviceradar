-- OCSF Core Event Streams Migration
-- This migration creates the foundational OCSF-aligned streams for ServiceRadar
-- Based on OCSF schema with Timeplus Proton streaming constraints

-- Device Inventory Events (discovery.device_inventory_info)
-- OCSF Class: 5001 (Device Inventory Info)
DROP STREAM IF EXISTS ocsf_device_inventory;
CREATE STREAM ocsf_device_inventory (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    activity_id int32 DEFAULT 1,           -- OCSF: activity (Create = 1, Update = 2, Delete = 3)
    category_uid int32 DEFAULT 5,          -- OCSF: Discovery = 5
    class_uid int32 DEFAULT 5001,          -- OCSF: Device Inventory Info = 5001
    severity_id int32 DEFAULT 1,           -- OCSF: Informational = 1

    -- Device Object (OCSF device)
    device_uid string,                     -- OCSF: device.uid (primary identifier)
    device_name string DEFAULT '',         -- OCSF: device.name (hostname)
    device_ip array(string) DEFAULT [],    -- OCSF: device.ip (all discovered IPs)
    device_mac array(string) DEFAULT [],   -- OCSF: device.mac (all discovered MACs)
    device_type_id int32 DEFAULT 0,        -- OCSF: device.type_id (Unknown=0, Computer=1, Mobile=7, etc)
    device_os_name string DEFAULT '',      -- OCSF: device.os.name
    device_os_version string DEFAULT '',   -- OCSF: device.os.version
    device_location string DEFAULT '',     -- OCSF: device.location (site/geo info)
    device_domain string DEFAULT '',       -- OCSF: device.domain

    -- Discovery Context
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',
    discovery_source string DEFAULT '',    -- 'sweep', 'netbox', 'armis', 'dhcp', etc.
    confidence_level int32 DEFAULT 3,     -- High=1, Medium=2, Low=3, Unknown=4

    -- Enrichment Data
    raw_data string DEFAULT '',           -- Original JSON from data source
    enrichments map(string, string),
    metadata map(string, string),

    -- Observable Flattening (for fast cross-entity searches)
    observables_ip array(string) DEFAULT [],
    observables_mac array(string) DEFAULT [],
    observables_hostname array(string) DEFAULT [],
    observables_domain array(string) DEFAULT [],
    observables_resource_uid array(string)) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)  -- Hourly partitions
ORDER BY (time, device_uid)
TTL to_start_of_day(time) + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;

-- Network Activity Events (network.network_activity)
-- OCSF Class: 4001 (Network Activity)
DROP STREAM IF EXISTS ocsf_network_activity;
CREATE STREAM ocsf_network_activity (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    start_time DateTime64(3) DEFAULT now64(),
    end_time DateTime64(3) DEFAULT now64(),
    activity_id int32 DEFAULT 1,           -- Traffic = 1, Flow = 5, Connection = 6
    category_uid int32 DEFAULT 4,          -- Network Activity = 4
    class_uid int32 DEFAULT 4001,          -- Network Activity = 4001
    severity_id int32 DEFAULT 1,           -- Informational = 1

    -- Connection Object (OCSF connection)
    connection_uid string DEFAULT '',      -- Unique flow identifier
    protocol_num int32 DEFAULT 0,          -- IP protocol number (6=TCP, 17=UDP, 1=ICMP)
    protocol_ver int32 DEFAULT 4,          -- IP version (4 or 6)

    -- Source Endpoint (OCSF src_endpoint)
    src_endpoint_ip string DEFAULT '',
    src_endpoint_port int32 DEFAULT 0,
    src_endpoint_mac string DEFAULT '',
    src_endpoint_hostname string DEFAULT '',
    src_endpoint_domain string DEFAULT '',

    -- Destination Endpoint (OCSF dst_endpoint)
    dst_endpoint_ip string DEFAULT '',
    dst_endpoint_port int32 DEFAULT 0,
    dst_endpoint_mac string DEFAULT '',
    dst_endpoint_hostname string DEFAULT '',
    dst_endpoint_domain string DEFAULT '',

    -- Traffic Object (OCSF traffic)
    traffic_bytes_in int64 DEFAULT 0,
    traffic_bytes_out int64 DEFAULT 0,
    traffic_packets_in int64 DEFAULT 0,
    traffic_packets_out int64 DEFAULT 0,

    -- ServiceRadar Specific Fields
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',
    sampler_address string DEFAULT '',     -- NetFlow exporter IP
    input_snmp int32 DEFAULT 0,            -- Input interface index
    output_snmp int32 DEFAULT 0,           -- Output interface index
    flow_direction_id int32 DEFAULT 0,     -- Inbound=1, Outbound=2, Unknown=0

    -- Enrichment Data
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Observable Flattening
    observables_ip array(string) DEFAULT [],
    observables_port array(string) DEFAULT [],      -- Format: "ip:port"
    observables_hostname array(string) DEFAULT [],
    observables_mac array(string)) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, src_endpoint_ip, dst_endpoint_ip)
TTL to_start_of_day(time) + INTERVAL 3 DAY        -- Shorter retention for high-volume data
SETTINGS index_granularity = 8192;

-- User Inventory Events (discovery.user_inventory_info)
-- OCSF Class: 5002 (User Inventory Info)
DROP STREAM IF EXISTS ocsf_user_inventory;
CREATE STREAM ocsf_user_inventory (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    activity_id int32 DEFAULT 1,
    category_uid int32 DEFAULT 5,          -- Discovery = 5
    class_uid int32 DEFAULT 5002,          -- User Inventory Info = 5002
    severity_id int32 DEFAULT 1,

    -- User Object (OCSF user)
    user_uid string,                       -- Primary identifier
    user_name string DEFAULT '',           -- Username/login
    user_email string DEFAULT '',
    user_full_name string DEFAULT '',
    user_domain string DEFAULT '',         -- Domain/realm
    user_type_id int32 DEFAULT 0,          -- Unknown=0, User=1, Admin=2, System=3
    user_credential_uid string DEFAULT '', -- Associated credential ID

    -- Account Object (OCSF account)
    account_name string DEFAULT '',        -- Account name if different from username
    account_type_id int32 DEFAULT 0,       -- Unknown=0, LDAP=1, Windows=2, etc
    account_uid string DEFAULT '',

    -- Discovery Context
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',
    discovery_source string DEFAULT '',    -- 'ad', 'ldap', 'local', etc.
    confidence_level int32 DEFAULT 3,

    -- Enrichment Data
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Observable Flattening
    observables_username array(string) DEFAULT [],
    observables_email array(string) DEFAULT [],
    observables_hostname array(string) DEFAULT [],
    observables_domain array(string) DEFAULT [],
    observables_resource_uid array(string)) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, user_uid)
TTL to_start_of_day(time) + INTERVAL 90 DAY        -- Longer retention for compliance
SETTINGS index_granularity = 8192;

-- System Activity Events (system.system_activity)
-- OCSF Class: 1001 (System Activity)
DROP STREAM IF EXISTS ocsf_system_activity;
CREATE STREAM ocsf_system_activity (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    activity_id int32 DEFAULT 0,           -- Varies by activity type
    activity_name string DEFAULT '',       -- Human-readable activity name
    category_uid int32 DEFAULT 1,          -- System Activity = 1
    class_uid int32 DEFAULT 1001,          -- System Activity = 1001
    severity_id int32 DEFAULT 1,

    -- Activity Details
    message string DEFAULT '',             -- Log message/description
    status string DEFAULT '',              -- Success, Failure, etc.
    status_code string DEFAULT '',         -- Numeric/string status code

    -- Actor Object (OCSF actor)
    actor_process_name string DEFAULT '',
    actor_process_pid int32 DEFAULT 0,
    actor_user_name string DEFAULT '',
    actor_user_uid string DEFAULT '',

    -- Endpoint Object (OCSF endpoint - where activity occurred)
    endpoint_hostname string DEFAULT '',
    endpoint_ip string DEFAULT '',
    endpoint_mac string DEFAULT '',
    endpoint_domain string DEFAULT '',
    endpoint_os_name string DEFAULT '',

    -- ServiceRadar Specific
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',
    log_level string DEFAULT '',           -- DEBUG, INFO, WARN, ERROR
    service_name string DEFAULT '',        -- Service that generated the event
    component string DEFAULT '',           -- Software component

    -- Enrichment Data
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Observable Flattening
    observables_ip array(string) DEFAULT [],
    observables_hostname array(string) DEFAULT [],
    observables_username array(string) DEFAULT [],
    observables_process array(string)) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, endpoint_hostname, service_name)
TTL to_start_of_day(time) + INTERVAL 7 DAY
SETTINGS index_granularity = 8192;