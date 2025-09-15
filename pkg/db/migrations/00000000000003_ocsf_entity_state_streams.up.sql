-- OCSF Entity State Streams Migration
-- These versioned_kv streams maintain current entity state for fast lookups
-- Compatible with Timeplus Proton's versioned key-value stream mode

-- Current Device State (versioned_kv)
-- Maintains the latest known state for each device across all discovery sources
CREATE STREAM ocsf_devices_current (
    -- Primary Key and Timestamps
    device_uid string,                     -- Primary key - unique device identifier
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),
    _tp_time DateTime64(3) DEFAULT now64(), -- Proton version column

    -- OCSF Device Object Fields
    device_name string DEFAULT '',         -- Current hostname
    device_ip array(string) DEFAULT [],    -- All known IP addresses
    device_mac array(string) DEFAULT [],   -- All known MAC addresses
    device_type_id int32DEFAULT 0,        -- OCSF device type
    device_os_name string DEFAULT '',
    device_os_version string DEFAULT '',
    device_location string DEFAULT '',
    device_domain string DEFAULT '',

    -- Aggregated Discovery Data
    discovery_sources array(string) DEFAULT [],  -- All sources that found this device
    confidence_score float32DEFAULT 0.0,        -- Confidence in data accuracy (0.0-1.0)
    discovery_count int32DEFAULT 0,             -- Number of times discovered

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',            -- Last reporting agent
    poller_id string DEFAULT '',           -- Last reporting poller
    is_available boolDEFAULT true,        -- Device availability status
    last_response_time DateTime64(3) DEFAULT now64(),

    -- State Management
    status string DEFAULT 'active',        -- active, inactive, deleted
    tags array(string) DEFAULT [],         -- User-defined tags
    categories array(string) DEFAULT [],   -- Device categories

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',           -- Latest raw discovery data
    enrichments map(string, string) DEFAULT map(),
    metadata map(string, string) DEFAULT map(),

-- Pre-computed Observable Arrays (for fast observable-based searches)
    observables_ip array(string) DEFAULT [],
    observables_mac array(string) DEFAULT [],
    observables_hostname array(string) DEFAULT [],
    observables_domain array(string) DEFAULT [],
    observables_resource_uid array(string) DEFAULT []

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
    user_name string DEFAULT '',           -- Username/login
    user_email string DEFAULT '',
    user_full_name string DEFAULT '',
    user_domain string DEFAULT '',
    user_type_id int32DEFAULT 0,
    user_credential_uid string DEFAULT '',

    -- Account Information
    account_name string DEFAULT '',
    account_type_id int32DEFAULT 0,
    account_uid string DEFAULT '',

    -- Aggregated Discovery Data
    discovery_sources array(string) DEFAULT [],
    confidence_score float32DEFAULT 0.0,
    discovery_count int32DEFAULT 0,

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',
    is_active boolDEFAULT true,           -- Account active status
    last_login DateTime64(3) DEFAULT now64(),

    -- State Management
    status string DEFAULT 'active',
    groups array(string) DEFAULT [],       -- User groups/roles
    permissions array(string) DEFAULT [],  -- Assigned permissions

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',
    metadata map(string, string) DEFAULT map(),

    -- Pre-computed Observable Arrays
    observables_username array(string) DEFAULT [],
    observables_email array(string) DEFAULT [],
    observables_hostname array(string) DEFAULT [],
    observables_domain array(string) DEFAULT [],
    observables_resource_uid array(string) DEFAULT []

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
    title string DEFAULT '',
    desc string DEFAULT '',               -- Vulnerability description
    severity_id int32DEFAULT 0,         -- Critical=1, High=2, Medium=3, Low=4
    score float32DEFAULT 0.0,           -- CVSS score

    -- Affected Resources
    affected_devices array(string) DEFAULT [],     -- Device UIDs affected
    affected_users array(string) DEFAULT [],       -- User UIDs affected
    affected_services array(string) DEFAULT [],    -- Service names affected

    -- Vulnerability Details
    cwe_uid string DEFAULT '',            -- Common Weakness Enumeration
    references array(string) DEFAULT [], -- URLs to vulnerability details
    remediation string DEFAULT '',        -- Fix/mitigation steps

    -- Discovery Context
    discovery_sources array(string) DEFAULT [],
    confidence_score float32DEFAULT 0.0,
    scanner_names array(string) DEFAULT [],

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',

    -- State Management
    status string DEFAULT 'open',         -- open, fixed, mitigated, false_positive
    priority string DEFAULT 'medium',     -- critical, high, medium, low
    assigned_to string DEFAULT '',        -- User responsible for remediation

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',
    metadata map(string, string) DEFAULT map(),

    -- Pre-computed Observable Arrays
    observables_cve array(string) DEFAULT [],
    observables_cwe array(string) DEFAULT [],
    observables_resource_uid array(string) DEFAULT []

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
    service_name string DEFAULT '',        -- Service/application name
    service_version string DEFAULT '',     -- Version information
    service_port int32DEFAULT 0,         -- Primary port
    service_protocol string DEFAULT '',   -- tcp, udp, etc.
    service_description string DEFAULT '',

    -- Location Information
    device_uid string DEFAULT '',         -- Device hosting the service
    device_hostname string DEFAULT '',
    device_ip string DEFAULT '',

    -- Service State
    is_running boolDEFAULT true,         -- Service status
    response_time_ms float32DEFAULT 0.0, -- Average response time

    -- Discovery Context
    discovery_sources array(string) DEFAULT [],
    confidence_score float32DEFAULT 0.0,

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',

    -- State Management
    status string DEFAULT 'active',
    tags array(string) DEFAULT [],
    categories array(string) DEFAULT [],

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',
    metadata map(string, string) DEFAULT map(),

    -- Pre-computed Observable Arrays
    observables_service array(string) DEFAULT [],    -- service:port combinations
    observables_ip array(string) DEFAULT [],
    observables_hostname array(string) DEFAULT [],
    observables_resource_uid array(string) DEFAULT []

) PRIMARY KEY (service_uid)
TTL to_start_of_day(last_seen) + INTERVAL 90 DAY
SETTINGS mode='versioned_kv', version_column='_tp_time';
