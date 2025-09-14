-- OCSF Core Event Streams Migration
-- This migration creates the foundational OCSF-aligned streams for ServiceRadar
-- Based on OCSF schema with Timeplus Proton streaming constraints

-- Device Inventory Events (discovery.device_inventory_info)
-- OCSF Class: 5001 (Device Inventory Info)
CREATE STREAM ocsf_device_inventory (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    activity_id Int32 DEFAULT 1,           -- OCSF: activity (Create = 1, Update = 2, Delete = 3)
    category_uid Int32 DEFAULT 5,          -- OCSF: Discovery = 5
    class_uid Int32 DEFAULT 5001,          -- OCSF: Device Inventory Info = 5001
    severity_id Int32 DEFAULT 1,           -- OCSF: Informational = 1

    -- Device Object (OCSF device)
    device_uid String,                     -- OCSF: device.uid (primary identifier)
    device_name String DEFAULT '',         -- OCSF: device.name (hostname)
    device_ip Array(String) DEFAULT [],    -- OCSF: device.ip (all discovered IPs)
    device_mac Array(String) DEFAULT [],   -- OCSF: device.mac (all discovered MACs)
    device_type_id Int32 DEFAULT 0,        -- OCSF: device.type_id (Unknown=0, Computer=1, Mobile=7, etc)
    device_os_name String DEFAULT '',      -- OCSF: device.os.name
    device_os_version String DEFAULT '',   -- OCSF: device.os.version
    device_location String DEFAULT '',     -- OCSF: device.location (site/geo info)
    device_domain String DEFAULT '',       -- OCSF: device.domain

    -- Discovery Context
    agent_id String DEFAULT '',
    poller_id String DEFAULT '',
    discovery_source String DEFAULT '',    -- 'sweep', 'netbox', 'armis', 'dhcp', etc.
    confidence_level Int32 DEFAULT 3,     -- High=1, Medium=2, Low=3, Unknown=4

    -- Enrichment Data
    raw_data String DEFAULT '',           -- Original JSON from data source
    enrichments Map(String, String) DEFAULT map(),
    metadata Map(String, String) DEFAULT map(),

    -- Observable Flattening (for fast cross-entity searches)
    observables_ip Array(String) DEFAULT [],
    observables_mac Array(String) DEFAULT [],
    observables_hostname Array(String) DEFAULT [],
    observables_domain Array(String) DEFAULT [],
    observables_resource_uid Array(String) DEFAULT []
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)  -- Hourly partitions
ORDER BY (time, device_uid)
TTL to_start_of_day(time) + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;

-- Network Activity Events (network.network_activity)
-- OCSF Class: 4001 (Network Activity)
CREATE STREAM ocsf_network_activity (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    start_time DateTime64(3) DEFAULT now64(),
    end_time DateTime64(3) DEFAULT now64(),
    activity_id Int32 DEFAULT 1,           -- Traffic = 1, Flow = 5, Connection = 6
    category_uid Int32 DEFAULT 4,          -- Network Activity = 4
    class_uid Int32 DEFAULT 4001,          -- Network Activity = 4001
    severity_id Int32 DEFAULT 1,           -- Informational = 1

    -- Connection Object (OCSF connection)
    connection_uid String DEFAULT '',      -- Unique flow identifier
    protocol_num Int32 DEFAULT 0,          -- IP protocol number (6=TCP, 17=UDP, 1=ICMP)
    protocol_ver Int32 DEFAULT 4,          -- IP version (4 or 6)

    -- Source Endpoint (OCSF src_endpoint)
    src_endpoint_ip String DEFAULT '',
    src_endpoint_port Int32 DEFAULT 0,
    src_endpoint_mac String DEFAULT '',
    src_endpoint_hostname String DEFAULT '',
    src_endpoint_domain String DEFAULT '',

    -- Destination Endpoint (OCSF dst_endpoint)
    dst_endpoint_ip String DEFAULT '',
    dst_endpoint_port Int32 DEFAULT 0,
    dst_endpoint_mac String DEFAULT '',
    dst_endpoint_hostname String DEFAULT '',
    dst_endpoint_domain String DEFAULT '',

    -- Traffic Object (OCSF traffic)
    traffic_bytes_in Int64 DEFAULT 0,
    traffic_bytes_out Int64 DEFAULT 0,
    traffic_packets_in Int64 DEFAULT 0,
    traffic_packets_out Int64 DEFAULT 0,

    -- ServiceRadar Specific Fields
    agent_id String DEFAULT '',
    poller_id String DEFAULT '',
    sampler_address String DEFAULT '',     -- NetFlow exporter IP
    input_snmp Int32 DEFAULT 0,            -- Input interface index
    output_snmp Int32 DEFAULT 0,           -- Output interface index
    flow_direction_id Int32 DEFAULT 0,     -- Inbound=1, Outbound=2, Unknown=0

    -- Enrichment Data
    raw_data String DEFAULT '',
    metadata Map(String, String) DEFAULT map(),

    -- Observable Flattening
    observables_ip Array(String) DEFAULT [],
    observables_port Array(String) DEFAULT [],      -- Format: "ip:port"
    observables_hostname Array(String) DEFAULT [],
    observables_mac Array(String) DEFAULT []
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, src_endpoint_ip, dst_endpoint_ip)
TTL to_start_of_day(time) + INTERVAL 3 DAY        -- Shorter retention for high-volume data
SETTINGS index_granularity = 8192;

-- User Inventory Events (discovery.user_inventory_info)
-- OCSF Class: 5002 (User Inventory Info)
CREATE STREAM ocsf_user_inventory (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    activity_id Int32 DEFAULT 1,
    category_uid Int32 DEFAULT 5,          -- Discovery = 5
    class_uid Int32 DEFAULT 5002,          -- User Inventory Info = 5002
    severity_id Int32 DEFAULT 1,

    -- User Object (OCSF user)
    user_uid String,                       -- Primary identifier
    user_name String DEFAULT '',           -- Username/login
    user_email String DEFAULT '',
    user_full_name String DEFAULT '',
    user_domain String DEFAULT '',         -- Domain/realm
    user_type_id Int32 DEFAULT 0,          -- Unknown=0, User=1, Admin=2, System=3
    user_credential_uid String DEFAULT '', -- Associated credential ID

    -- Account Object (OCSF account)
    account_name String DEFAULT '',        -- Account name if different from username
    account_type_id Int32 DEFAULT 0,       -- Unknown=0, LDAP=1, Windows=2, etc
    account_uid String DEFAULT '',

    -- Discovery Context
    agent_id String DEFAULT '',
    poller_id String DEFAULT '',
    discovery_source String DEFAULT '',    -- 'ad', 'ldap', 'local', etc.
    confidence_level Int32 DEFAULT 3,

    -- Enrichment Data
    raw_data String DEFAULT '',
    metadata Map(String, String) DEFAULT map(),

    -- Observable Flattening
    observables_username Array(String) DEFAULT [],
    observables_email Array(String) DEFAULT [],
    observables_hostname Array(String) DEFAULT [],
    observables_domain Array(String) DEFAULT [],
    observables_resource_uid Array(String) DEFAULT []
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, user_uid)
TTL to_start_of_day(time) + INTERVAL 90 DAY        -- Longer retention for compliance
SETTINGS index_granularity = 8192;

-- System Activity Events (system.system_activity)
-- OCSF Class: 1001 (System Activity)
CREATE STREAM ocsf_system_activity (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    activity_id Int32 DEFAULT 0,           -- Varies by activity type
    activity_name String DEFAULT '',       -- Human-readable activity name
    category_uid Int32 DEFAULT 1,          -- System Activity = 1
    class_uid Int32 DEFAULT 1001,          -- System Activity = 1001
    severity_id Int32 DEFAULT 1,

    -- Activity Details
    message String DEFAULT '',             -- Log message/description
    status String DEFAULT '',              -- Success, Failure, etc.
    status_code String DEFAULT '',         -- Numeric/string status code

    -- Actor Object (OCSF actor)
    actor_process_name String DEFAULT '',
    actor_process_pid Int32 DEFAULT 0,
    actor_user_name String DEFAULT '',
    actor_user_uid String DEFAULT '',

    -- Endpoint Object (OCSF endpoint - where activity occurred)
    endpoint_hostname String DEFAULT '',
    endpoint_ip String DEFAULT '',
    endpoint_mac String DEFAULT '',
    endpoint_domain String DEFAULT '',
    endpoint_os_name String DEFAULT '',

    -- ServiceRadar Specific
    agent_id String DEFAULT '',
    poller_id String DEFAULT '',
    log_level String DEFAULT '',           -- DEBUG, INFO, WARN, ERROR
    service_name String DEFAULT '',        -- Service that generated the event
    component String DEFAULT '',           -- Software component

    -- Enrichment Data
    raw_data String DEFAULT '',
    metadata Map(String, String) DEFAULT map(),

    -- Observable Flattening
    observables_ip Array(String) DEFAULT [],
    observables_hostname Array(String) DEFAULT [],
    observables_username Array(String) DEFAULT [],
    observables_process Array(String) DEFAULT []
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, endpoint_hostname, service_name)
TTL to_start_of_day(time) + INTERVAL 7 DAY
SETTINGS index_granularity = 8192;