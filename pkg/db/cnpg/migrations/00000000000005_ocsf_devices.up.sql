-- Add OCSF device inventory table for existing deployments.
-- Safe for fresh installs (IF NOT EXISTS) and upgrades from unified_devices.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

DROP TABLE IF EXISTS unified_devices;

CREATE TABLE IF NOT EXISTS ocsf_devices (
    -- OCSF Core Identity
    uid                 TEXT              PRIMARY KEY,  -- Canonical device ID from DIRE (sr: prefixed UUID)
    type_id             INTEGER           NOT NULL DEFAULT 0,  -- OCSF device type enum (0=Unknown, 1=Server, 2=Desktop, etc.)
    type                TEXT,             -- Human-readable device type name
    name                TEXT,             -- Administrator-assigned device name
    hostname            TEXT,             -- Device hostname
    ip                  TEXT,             -- Primary IP address
    mac                 TEXT,             -- Primary MAC address

    -- OCSF Extended Identity
    uid_alt             TEXT,             -- Alternate unique identifier (e.g., ActiveDirectory DN)
    vendor_name         TEXT,             -- Device manufacturer (e.g., Dell, Cisco)
    model               TEXT,             -- Device model identifier
    domain              TEXT,             -- Network domain (e.g., work.example.com)
    zone                TEXT,             -- Network zone or LAN segment
    subnet_uid          TEXT,             -- Virtual subnet unique identifier
    vlan_uid            TEXT,             -- Virtual LAN identifier
    region              TEXT,             -- Geographic region

    -- OCSF Temporal
    first_seen_time     TIMESTAMPTZ,      -- When device was first discovered
    last_seen_time      TIMESTAMPTZ,      -- When device was last observed
    created_time        TIMESTAMPTZ       NOT NULL DEFAULT now(),  -- When record was created
    modified_time       TIMESTAMPTZ       NOT NULL DEFAULT now(),  -- When record was last modified

    -- OCSF Risk and Compliance
    risk_level_id       INTEGER,          -- Normalized risk level (0=Info, 1=Low, 2=Medium, 3=High, 4=Critical)
    risk_level          TEXT,             -- Risk level caption
    risk_score          INTEGER,          -- Numeric risk score from source system
    is_managed          BOOLEAN,          -- Device is managed by MDM/endpoint management
    is_compliant        BOOLEAN,          -- Device meets compliance requirements
    is_trusted          BOOLEAN,          -- Device is trusted for network access

    -- OCSF Nested Objects (stored as JSONB)
    os                  JSONB,            -- {name, type, type_id, version, build, edition, kernel_release, cpu_bits, sp_name, sp_ver, lang}
    hw_info             JSONB,            -- {cpu_architecture, cpu_bits, cpu_cores, cpu_count, cpu_speed_mhz, cpu_type, ram_size, serial_number, chassis, bios_manufacturer, bios_ver, bios_date, uuid}
    network_interfaces  JSONB,            -- [{mac, ip, hostname, name, uid, type, type_id}]
    owner               JSONB,            -- {uid, name, email, type, type_id}
    org                 JSONB,            -- {uid, name, ou_uid, ou_name}
    groups              JSONB,            -- [{uid, name, type, desc}]
    agent_list          JSONB,            -- [{uid, name, type, type_id, version, vendor_name}]

    -- ServiceRadar-specific fields
    gateway_id           TEXT,             -- Reporting gateway
    agent_id            TEXT,             -- Reporting agent
    discovery_sources   TEXT[],           -- Sources that discovered this device
    is_available        BOOLEAN,          -- Device availability status
    metadata            JSONB             -- Additional unstructured metadata
);

-- Indexes for ocsf_devices
CREATE INDEX IF NOT EXISTS idx_ocsf_devices_ip ON ocsf_devices (ip);
CREATE INDEX IF NOT EXISTS idx_ocsf_devices_type_id ON ocsf_devices (type_id);
CREATE INDEX IF NOT EXISTS idx_ocsf_devices_last_seen ON ocsf_devices (last_seen_time);
CREATE INDEX IF NOT EXISTS idx_ocsf_devices_vendor ON ocsf_devices (vendor_name);
-- Trigram indexes for ILIKE queries
CREATE INDEX IF NOT EXISTS idx_ocsf_devices_hostname_trgm ON ocsf_devices USING gin (hostname gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_ocsf_devices_ip_trgm ON ocsf_devices USING gin (ip gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_ocsf_devices_name_trgm ON ocsf_devices USING gin (name gin_trgm_ops);
-- GIN indexes for JSONB queries
CREATE INDEX IF NOT EXISTS idx_ocsf_devices_os_gin ON ocsf_devices USING gin (os);
CREATE INDEX IF NOT EXISTS idx_ocsf_devices_metadata_gin ON ocsf_devices USING gin (metadata);
