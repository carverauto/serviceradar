-- OCSF Entity State Streams Migration
-- These versioned_kv streams maintain current entity state for fast lookups
-- Compatible with Timeplus Proton's versioned key-value stream mode

-- Current Device State (versioned_kv)
-- Maintains the latest known state for each device across all discovery sources
DROP STREAM IF EXISTS ocsf_devices_current;
CREATE STREAM ocsf_devices_current (
    -- Primary Key and Timestamps
    device_uid string,                     -- Primary key - unique device identifier
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),

    -- OCSF Device Object Fields
    device_name string DEFAULT '',         -- Current hostname
    device_ip array(string),    -- All known IP addresses
    device_mac array(string),   -- All known MAC addresses
    device_type_id int32 DEFAULT 0,        -- OCSF device type
    device_os_name string DEFAULT '',
    device_os_version string DEFAULT '',
    device_location string DEFAULT '',
    device_domain string DEFAULT '',

    -- Aggregated Discovery Data
    discovery_sources array(string),  -- All sources that found this device
    confidence_score float32 DEFAULT 0.0,        -- Confidence in data accuracy (0.0-1.0)
    discovery_count int32 DEFAULT 0,             -- Number of times discovered

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',            -- Last reporting agent
    poller_id string DEFAULT '',           -- Last reporting poller
    is_available bool DEFAULT true,        -- Device availability status
    last_response_time DateTime64(3) DEFAULT now64(),

    -- State Management
    status string DEFAULT 'active',        -- active, inactive, deleted
    tags array(string),         -- User-defined tags
    categories array(string),   -- Device categories

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',           -- Latest raw discovery data
    enrichments map(string, string),
    metadata map(string, string),

-- Pre-computed Observable Arrays (for fast observable-based searches)
    observables_ip array(string),
    observables_mac array(string),
    observables_hostname array(string),
    observables_domain array(string),
    observables_resource_uid array(string)
) PRIMARY KEY (device_uid)
TTL to_start_of_day(last_seen) + INTERVAL 90 DAY
SETTINGS mode='versioned_kv';

-- Current User State (versioned_kv)
-- Maintains the latest known state for each user account
DROP STREAM IF EXISTS ocsf_users_current;
CREATE STREAM ocsf_users_current (
    -- Primary Key and Timestamps
    user_uid string,                       -- Primary key - unique user identifier
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),

    -- OCSF User Object Fields
    user_name string DEFAULT '',           -- Username/login
    user_email string DEFAULT '',
    user_full_name string DEFAULT '',
    user_domain string DEFAULT '',
    user_type_id int32 DEFAULT 0,
    user_credential_uid string DEFAULT '',

    -- Account Information
    account_name string DEFAULT '',
    account_type_id int32 DEFAULT 0,
    account_uid string DEFAULT '',

    -- Aggregated Discovery Data
    discovery_sources array(string),
    confidence_score float32 DEFAULT 0.0,
    discovery_count int32 DEFAULT 0,

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',
    is_active bool DEFAULT true,           -- Account active status
    last_login DateTime64(3) DEFAULT now64(),

    -- State Management
    status string DEFAULT 'active',
    groups array(string),       -- User groups/roles
    permissions array(string),  -- Assigned permissions

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Pre-computed Observable Arrays
    observables_username array(string),
    observables_email array(string),
    observables_hostname array(string),
    observables_domain array(string),
    observables_resource_uid array(string)
) PRIMARY KEY (user_uid)
TTL to_start_of_day(last_seen) + INTERVAL 90 DAY
SETTINGS mode='versioned_kv';

-- Current Vulnerability State (versioned_kv)
-- Tracks current vulnerability findings across all affected resources
DROP STREAM IF EXISTS ocsf_vulnerabilities_current;
CREATE STREAM ocsf_vulnerabilities_current (
    -- Primary Key and Timestamps
    vulnerability_cve_uid string,          -- Primary key - CVE ID or internal vuln ID
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),

    -- OCSF Vulnerability Object Fields
    title string DEFAULT '',
    desc string DEFAULT '',               -- Vulnerability description
    severity_id int32 DEFAULT 0,         -- Critical=1, High=2, Medium=3, Low=4
    score float32 DEFAULT 0.0,           -- CVSS score

    -- Affected Resources
    affected_devices array(string),     -- Device UIDs affected
    affected_users array(string),       -- User UIDs affected
    affected_services array(string),    -- Service names affected

    -- Vulnerability Details
    cwe_uid string DEFAULT '',            -- Common Weakness Enumeration
    references array(string), -- URLs to vulnerability details
    remediation string DEFAULT '',        -- Fix/mitigation steps

    -- Discovery Context
    discovery_sources array(string),
    confidence_score float32 DEFAULT 0.0,
    scanner_names array(string),

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',

    -- State Management
    status string DEFAULT 'open',         -- open, fixed, mitigated, false_positive
    priority string DEFAULT 'medium',     -- critical, high, medium, low
    assigned_to string DEFAULT '',        -- User responsible for remediation

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Pre-computed Observable Arrays
    observables_cve array(string),
    observables_cwe array(string),
    observables_resource_uid array(string)
) PRIMARY KEY (vulnerability_cve_uid)
TTL to_start_of_day(last_seen) + INTERVAL 365 DAY  -- Keep vulnerabilities for 1 year
SETTINGS mode='versioned_kv';

-- Current Service State (versioned_kv)
-- Tracks discovered services and applications
DROP STREAM IF EXISTS ocsf_services_current;
CREATE STREAM ocsf_services_current (
    -- Primary Key and Timestamps
    service_uid string,                    -- Primary key - service identifier
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),

    -- Service Information
    service_name string DEFAULT '',        -- Service/application name
    service_version string DEFAULT '',     -- Version information
    service_port int32 DEFAULT 0,         -- Primary port
    service_protocol string DEFAULT '',   -- tcp, udp, etc.
    service_description string DEFAULT '',

    -- Location Information
    device_uid string DEFAULT '',         -- Device hosting the service
    device_hostname string DEFAULT '',
    device_ip string DEFAULT '',

    -- Service State
    is_running bool DEFAULT true,         -- Service status
    response_time_ms float32 DEFAULT 0.0, -- Average response time

    -- Discovery Context
    discovery_sources array(string),
    confidence_score float32 DEFAULT 0.0,

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',

    -- State Management
    status string DEFAULT 'active',
    tags array(string),
    categories array(string),

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Pre-computed Observable Arrays
    observables_service array(string),    -- service:port combinations
    observables_ip array(string),
    observables_hostname array(string),
    observables_resource_uid array(string)
) PRIMARY KEY (service_uid)
TTL to_start_of_day(last_seen) + INTERVAL 90 DAY
SETTINGS mode='versioned_kv';
