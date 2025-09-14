-- OCSF Entity State Streams Migration
-- These versioned_kv streams maintain current entity state for fast lookups
-- Compatible with Timeplus Proton's versioned key-value stream mode

-- Current Device State (versioned_kv)
-- Maintains the latest known state for each device across all discovery sources
CREATE STREAM ocsf_devices_current (
    -- Primary Key and Timestamps
    device_uid String,                     -- Primary key - unique device identifier
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),
    _tp_time DateTime64(3) DEFAULT now64(), -- Proton version column

    -- OCSF Device Object Fields
    device_name String DEFAULT '',         -- Current hostname
    device_ip Array(String) DEFAULT [],    -- All known IP addresses
    device_mac Array(String) DEFAULT [],   -- All known MAC addresses
    device_type_id Int32 DEFAULT 0,        -- OCSF device type
    device_os_name String DEFAULT '',
    device_os_version String DEFAULT '',
    device_location String DEFAULT '',
    device_domain String DEFAULT '',

    -- Aggregated Discovery Data
    discovery_sources Array(String) DEFAULT [],  -- All sources that found this device
    confidence_score Float32 DEFAULT 0.0,        -- Confidence in data accuracy (0.0-1.0)
    discovery_count Int32 DEFAULT 0,             -- Number of times discovered

    -- ServiceRadar Operational Fields
    agent_id String DEFAULT '',            -- Last reporting agent
    poller_id String DEFAULT '',           -- Last reporting poller
    is_available Bool DEFAULT true,        -- Device availability status
    last_response_time DateTime64(3) DEFAULT now64(),

    -- State Management
    status String DEFAULT 'active',        -- active, inactive, deleted
    tags Array(String) DEFAULT [],         -- User-defined tags
    categories Array(String) DEFAULT [],   -- Device categories

    -- Raw Data and Enrichments
    raw_data String DEFAULT '',           -- Latest raw discovery data
    enrichments Map(String, String) DEFAULT map(),
    metadata Map(String, String) DEFAULT map(),

-- Pre-computed Observable Arrays (for fast observable-based searches)
    observables_ip Array(String) DEFAULT [],
    observables_mac Array(String) DEFAULT [],
    observables_hostname Array(String) DEFAULT [],
    observables_domain Array(String) DEFAULT [],
    observables_resource_uid Array(String) DEFAULT []

) PRIMARY KEY (device_uid)
TTL to_start_of_day(last_seen) + INTERVAL 90 DAY
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Current User State (versioned_kv)
-- Maintains the latest known state for each user account
CREATE STREAM ocsf_users_current (
    -- Primary Key and Timestamps
    user_uid String,                       -- Primary key - unique user identifier
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),
    _tp_time DateTime64(3) DEFAULT now64(),

    -- OCSF User Object Fields
    user_name String DEFAULT '',           -- Username/login
    user_email String DEFAULT '',
    user_full_name String DEFAULT '',
    user_domain String DEFAULT '',
    user_type_id Int32 DEFAULT 0,
    user_credential_uid String DEFAULT '',

    -- Account Information
    account_name String DEFAULT '',
    account_type_id Int32 DEFAULT 0,
    account_uid String DEFAULT '',

    -- Aggregated Discovery Data
    discovery_sources Array(String) DEFAULT [],
    confidence_score Float32 DEFAULT 0.0,
    discovery_count Int32 DEFAULT 0,

    -- ServiceRadar Operational Fields
    agent_id String DEFAULT '',
    poller_id String DEFAULT '',
    is_active Bool DEFAULT true,           -- Account active status
    last_login DateTime64(3) DEFAULT now64(),

    -- State Management
    status String DEFAULT 'active',
    groups Array(String) DEFAULT [],       -- User groups/roles
    permissions Array(String) DEFAULT [],  -- Assigned permissions

    -- Raw Data and Enrichments
    raw_data String DEFAULT '',
    metadata Map(String, String) DEFAULT map(),

    -- Pre-computed Observable Arrays
    observables_username Array(String) DEFAULT [],
    observables_email Array(String) DEFAULT [],
    observables_hostname Array(String) DEFAULT [],
    observables_domain Array(String) DEFAULT [],
    observables_resource_uid Array(String) DEFAULT []

) PRIMARY KEY (user_uid)
TTL to_start_of_day(last_seen) + INTERVAL 90 DAY
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Current Vulnerability State (versioned_kv)
-- Tracks current vulnerability findings across all affected resources
CREATE STREAM ocsf_vulnerabilities_current (
    -- Primary Key and Timestamps
    vulnerability_cve_uid String,          -- Primary key - CVE ID or internal vuln ID
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),
    _tp_time DateTime64(3) DEFAULT now64(),

    -- OCSF Vulnerability Object Fields
    title String DEFAULT '',
    desc String DEFAULT '',               -- Vulnerability description
    severity_id Int32 DEFAULT 0,         -- Critical=1, High=2, Medium=3, Low=4
    score Float32 DEFAULT 0.0,           -- CVSS score

    -- Affected Resources
    affected_devices Array(String) DEFAULT [],     -- Device UIDs affected
    affected_users Array(String) DEFAULT [],       -- User UIDs affected
    affected_services Array(String) DEFAULT [],    -- Service names affected

    -- Vulnerability Details
    cwe_uid String DEFAULT '',            -- Common Weakness Enumeration
    references Array(String) DEFAULT [], -- URLs to vulnerability details
    remediation String DEFAULT '',        -- Fix/mitigation steps

    -- Discovery Context
    discovery_sources Array(String) DEFAULT [],
    confidence_score Float32 DEFAULT 0.0,
    scanner_names Array(String) DEFAULT [],

    -- ServiceRadar Operational Fields
    agent_id String DEFAULT '',
    poller_id String DEFAULT '',

    -- State Management
    status String DEFAULT 'open',         -- open, fixed, mitigated, false_positive
    priority String DEFAULT 'medium',     -- critical, high, medium, low
    assigned_to String DEFAULT '',        -- User responsible for remediation

    -- Raw Data and Enrichments
    raw_data String DEFAULT '',
    metadata Map(String, String) DEFAULT map(),

    -- Pre-computed Observable Arrays
    observables_cve Array(String) DEFAULT [],
    observables_cwe Array(String) DEFAULT [],
    observables_resource_uid Array(String) DEFAULT []

) PRIMARY KEY (vulnerability_cve_uid)
TTL to_start_of_day(last_seen) + INTERVAL 365 DAY  -- Keep vulnerabilities for 1 year
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Current Service State (versioned_kv)
-- Tracks discovered services and applications
CREATE STREAM ocsf_services_current (
    -- Primary Key and Timestamps
    service_uid String,                    -- Primary key - service identifier
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),
    _tp_time DateTime64(3) DEFAULT now64(),

    -- Service Information
    service_name String DEFAULT '',        -- Service/application name
    service_version String DEFAULT '',     -- Version information
    service_port Int32 DEFAULT 0,         -- Primary port
    service_protocol String DEFAULT '',   -- tcp, udp, etc.
    service_description String DEFAULT '',

    -- Location Information
    device_uid String DEFAULT '',         -- Device hosting the service
    device_hostname String DEFAULT '',
    device_ip String DEFAULT '',

    -- Service State
    is_running Bool DEFAULT true,         -- Service status
    response_time_ms Float32 DEFAULT 0.0, -- Average response time

    -- Discovery Context
    discovery_sources Array(String) DEFAULT [],
    confidence_score Float32 DEFAULT 0.0,

    -- ServiceRadar Operational Fields
    agent_id String DEFAULT '',
    poller_id String DEFAULT '',

    -- State Management
    status String DEFAULT 'active',
    tags Array(String) DEFAULT [],
    categories Array(String) DEFAULT [],

    -- Raw Data and Enrichments
    raw_data String DEFAULT '',
    metadata Map(String, String) DEFAULT map(),

    -- Pre-computed Observable Arrays
    observables_service Array(String) DEFAULT [],    -- service:port combinations
    observables_ip Array(String) DEFAULT [],
    observables_hostname Array(String) DEFAULT [],
    observables_resource_uid Array(String) DEFAULT []

) PRIMARY KEY (service_uid)
TTL to_start_of_day(last_seen) + INTERVAL 90 DAY
SETTINGS mode='versioned_kv', version_column='_tp_time';
