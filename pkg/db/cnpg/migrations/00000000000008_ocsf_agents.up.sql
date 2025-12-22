-- Add OCSF agent registry table for storing agent metadata.
-- Aligns with OCSF v1.7.0 Agent object schema.
-- Agents are monitoring software components, separate from devices (monitored assets).

CREATE TABLE IF NOT EXISTS ocsf_agents (
    -- OCSF Core Identity (per https://schema.ocsf.io/1.7.0/objects/agent)
    uid                 TEXT              PRIMARY KEY,  -- Unique agent identifier (sensor ID)
    name                TEXT,             -- Agent designation (e.g., "serviceradar-agent")
    type_id             INTEGER           NOT NULL DEFAULT 0,  -- OCSF agent type enum
    type                TEXT,             -- Human-readable agent type name

    -- OCSF Extended Identity
    version             TEXT,             -- Semantic version of the agent
    vendor_name         TEXT,             -- Agent vendor (e.g., "ServiceRadar")
    uid_alt             TEXT,             -- Alternate unique identifier (e.g., configuration UID)
    policies            JSONB,            -- Applied policies array [{name, uid, version}]

    -- ServiceRadar Extensions
    poller_id           TEXT,             -- Parent poller reference
    capabilities        TEXT[],           -- Registered checker capabilities (icmp, snmp, sysmon, etc.)
    ip                  TEXT,             -- Agent IP address
    first_seen_time     TIMESTAMPTZ,      -- When agent first registered
    last_seen_time      TIMESTAMPTZ,      -- Last heartbeat time
    created_time        TIMESTAMPTZ       NOT NULL DEFAULT now(),  -- When record was created
    modified_time       TIMESTAMPTZ       NOT NULL DEFAULT now(),  -- When record was last modified
    metadata            JSONB             -- Additional unstructured metadata
);

-- OCSF Agent type_id enum values:
-- 0 = Unknown
-- 1 = Endpoint Detection and Response
-- 2 = Data Loss Prevention
-- 3 = Backup and Recovery
-- 4 = Performance Monitoring and Observability
-- 5 = Vulnerability Management
-- 6 = Log Management
-- 7 = Mobile Device Management
-- 8 = Configuration Management
-- 9 = Remote Access
-- 99 = Other

COMMENT ON TABLE ocsf_agents IS 'OCSF v1.7.0 Agent object registry - stores monitoring agent metadata';
COMMENT ON COLUMN ocsf_agents.uid IS 'Unique agent identifier (sensor ID)';
COMMENT ON COLUMN ocsf_agents.type_id IS 'OCSF agent type: 0=Unknown, 1=EDR, 4=Performance, 6=Log, 99=Other';
COMMENT ON COLUMN ocsf_agents.capabilities IS 'Checker capabilities this agent supports (icmp, snmp, sysmon, rperf, etc.)';

-- Indexes for ocsf_agents
CREATE INDEX IF NOT EXISTS idx_ocsf_agents_poller_id ON ocsf_agents (poller_id);
CREATE INDEX IF NOT EXISTS idx_ocsf_agents_type_id ON ocsf_agents (type_id);
CREATE INDEX IF NOT EXISTS idx_ocsf_agents_last_seen ON ocsf_agents (last_seen_time);
CREATE INDEX IF NOT EXISTS idx_ocsf_agents_ip ON ocsf_agents (ip);
-- GIN index for capabilities array queries
CREATE INDEX IF NOT EXISTS idx_ocsf_agents_capabilities ON ocsf_agents USING gin (capabilities);
-- Trigram index for name searches
CREATE INDEX IF NOT EXISTS idx_ocsf_agents_name_trgm ON ocsf_agents USING gin (name gin_trgm_ops);
