-- Consolidated idempotent schema for ServiceRadar CNPG/Timescale
-- This is the "scorched earth" schema that consolidates all prior migrations.
-- All statements use IF NOT EXISTS / IF EXISTS for idempotency.

-- ================================
-- Extensions
-- ================================
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ================================
-- Generic telemetry hypertables
-- ================================
CREATE TABLE IF NOT EXISTS timeseries_metrics (
    timestamp           TIMESTAMPTZ       NOT NULL,
    poller_id           TEXT              NOT NULL,
    agent_id            TEXT,
    metric_name         TEXT              NOT NULL,
    metric_type         TEXT              NOT NULL,
    device_id           TEXT,
    value               DOUBLE PRECISION  NOT NULL,
    unit                TEXT,
    tags                JSONB,
    partition           TEXT,
    scale               DOUBLE PRECISION,
    is_delta            BOOLEAN           DEFAULT FALSE,
    target_device_ip    TEXT,
    if_index            INTEGER,
    metadata            JSONB,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('timeseries_metrics','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('timeseries_metrics', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_device_time ON timeseries_metrics (device_id, timestamp DESC);

CREATE TABLE IF NOT EXISTS cpu_metrics (
    timestamp           TIMESTAMPTZ       NOT NULL,
    poller_id           TEXT              NOT NULL,
    agent_id            TEXT,
    host_id             TEXT,
    core_id             INTEGER,
    usage_percent       DOUBLE PRECISION,
    frequency_hz        DOUBLE PRECISION,
    label               TEXT,
    cluster             TEXT,
    device_id           TEXT,
    partition           TEXT,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('cpu_metrics','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('cpu_metrics', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_cpu_metrics_device_time ON cpu_metrics (device_id, timestamp DESC);

CREATE TABLE IF NOT EXISTS cpu_cluster_metrics (
    timestamp           TIMESTAMPTZ       NOT NULL,
    poller_id           TEXT,
    agent_id            TEXT,
    host_id             TEXT,
    cluster             TEXT,
    frequency_hz        DOUBLE PRECISION,
    device_id           TEXT,
    partition           TEXT,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('cpu_cluster_metrics','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('cpu_cluster_metrics', INTERVAL '3 days', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS disk_metrics (
    timestamp           TIMESTAMPTZ       NOT NULL,
    poller_id           TEXT,
    agent_id            TEXT,
    host_id             TEXT,
    mount_point         TEXT,
    device_name         TEXT,
    total_bytes         BIGINT,
    used_bytes          BIGINT,
    available_bytes     BIGINT,
    usage_percent       DOUBLE PRECISION,
    device_id           TEXT,
    partition           TEXT,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('disk_metrics','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('disk_metrics', INTERVAL '3 days', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS memory_metrics (
    timestamp           TIMESTAMPTZ       NOT NULL,
    poller_id           TEXT,
    agent_id            TEXT,
    host_id             TEXT,
    total_bytes         BIGINT,
    used_bytes          BIGINT,
    available_bytes     BIGINT,
    usage_percent       DOUBLE PRECISION,
    device_id           TEXT,
    partition           TEXT,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('memory_metrics','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('memory_metrics', INTERVAL '3 days', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS process_metrics (
    timestamp           TIMESTAMPTZ       NOT NULL,
    poller_id           TEXT,
    agent_id            TEXT,
    host_id             TEXT,
    pid                 INTEGER,
    name                TEXT,
    cpu_usage           REAL,
    memory_usage        BIGINT,
    status              TEXT,
    start_time          TEXT,
    device_id           TEXT,
    partition           TEXT,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('process_metrics','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('process_metrics', INTERVAL '3 days', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS netflow_metrics (
    timestamp           TIMESTAMPTZ       NOT NULL,
    poller_id           TEXT,
    agent_id            TEXT,
    device_id           TEXT,
    flow_direction      TEXT,
    src_addr            TEXT,
    dst_addr            TEXT,
    src_port            INTEGER,
    dst_port            INTEGER,
    protocol            INTEGER,
    packets             BIGINT,
    octets              BIGINT,
    sampler_address     TEXT,
    input_snmp          INTEGER,
    output_snmp         INTEGER,
    metadata            JSONB,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('netflow_metrics','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('netflow_metrics', INTERVAL '3 days', if_not_exists => TRUE);

-- ================================
-- Discovery + sweep data
-- ================================
CREATE TABLE IF NOT EXISTS sweep_host_states (
    host_ip             TEXT              NOT NULL,
    poller_id           TEXT              NOT NULL,
    agent_id            TEXT              NOT NULL,
    partition           TEXT              NOT NULL,
    network_cidr        TEXT,
    hostname            TEXT,
    mac                 TEXT,
    icmp_available      BOOLEAN,
    icmp_response_time_ns BIGINT,
    icmp_packet_loss    DOUBLE PRECISION,
    tcp_ports_scanned   JSONB,
    tcp_ports_open      JSONB,
    port_scan_results   JSONB,
    last_sweep_time     TIMESTAMPTZ       NOT NULL,
    first_seen          TIMESTAMPTZ,
    metadata            JSONB,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now(),
    PRIMARY KEY (host_ip, poller_id, partition, last_sweep_time)
);
SELECT create_hypertable('sweep_host_states','last_sweep_time', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('sweep_host_states', INTERVAL '3 days', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS discovered_interfaces (
    timestamp           TIMESTAMPTZ       NOT NULL,
    agent_id            TEXT,
    poller_id           TEXT,
    device_ip           TEXT,
    device_id           TEXT,
    if_index            INTEGER,
    if_name             TEXT,
    if_descr            TEXT,
    if_alias            TEXT,
    if_speed            BIGINT,
    if_phys_address     TEXT,
    ip_addresses        TEXT[],
    if_admin_status     INTEGER,
    if_oper_status      INTEGER,
    metadata            JSONB,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('discovered_interfaces','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('discovered_interfaces', INTERVAL '3 days', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS topology_discovery_events (
    timestamp                TIMESTAMPTZ   NOT NULL,
    agent_id                 TEXT,
    poller_id                TEXT,
    local_device_ip          TEXT,
    local_device_id          TEXT,
    local_if_index           INTEGER,
    local_if_name            TEXT,
    protocol_type            TEXT,
    neighbor_chassis_id      TEXT,
    neighbor_port_id         TEXT,
    neighbor_port_descr      TEXT,
    neighbor_system_name     TEXT,
    neighbor_management_addr TEXT,
    neighbor_bgp_router_id   TEXT,
    neighbor_ip_address      TEXT,
    neighbor_as              INTEGER,
    bgp_session_state        TEXT,
    metadata                 JSONB,
    created_at               TIMESTAMPTZ   NOT NULL DEFAULT now()
);
SELECT create_hypertable('topology_discovery_events','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('topology_discovery_events', INTERVAL '3 days', if_not_exists => TRUE);

-- ================================
-- Device inventory + updates
-- ================================
CREATE TABLE IF NOT EXISTS device_updates (
    observed_at         TIMESTAMPTZ       NOT NULL,
    agent_id            TEXT              NOT NULL,
    poller_id           TEXT              NOT NULL,
    partition           TEXT              NOT NULL,
    device_id           TEXT              NOT NULL,
    discovery_source    TEXT              NOT NULL,
    ip                  TEXT,
    mac                 TEXT,
    hostname            TEXT,
    available           BOOLEAN,
    metadata            JSONB,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('device_updates','observed_at', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('device_updates', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_device_updates_device_time ON device_updates (device_id, observed_at DESC);

-- ================================
-- OCSF Device Inventory (aligned with OCSF v1.7.0 Device object)
-- ================================
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
    poller_id           TEXT,             -- Reporting poller
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

-- ================================
-- Registry tables (pollers, agents, checkers)
-- ================================
CREATE TABLE IF NOT EXISTS pollers (
    poller_id           TEXT              PRIMARY KEY,
    component_id        TEXT              DEFAULT '',
    registration_source TEXT              DEFAULT 'implicit',
    status              TEXT              DEFAULT 'active',
    spiffe_identity     TEXT              DEFAULT '',
    first_registered    TIMESTAMPTZ       DEFAULT now(),
    first_seen          TIMESTAMPTZ,
    last_seen           TIMESTAMPTZ       DEFAULT now(),
    metadata            JSONB             DEFAULT '{}'::jsonb,
    created_by          TEXT              DEFAULT 'system',
    is_healthy          BOOLEAN           DEFAULT TRUE,
    agent_count         INTEGER           DEFAULT 0,
    checker_count       INTEGER           DEFAULT 0,
    updated_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pollers_last_seen ON pollers (last_seen DESC);

CREATE TABLE IF NOT EXISTS agents (
    agent_id            TEXT              PRIMARY KEY,
    poller_id           TEXT              NOT NULL,
    component_id        TEXT              DEFAULT '',
    registration_source TEXT              DEFAULT 'implicit',
    status              TEXT              DEFAULT 'active',
    spiffe_identity     TEXT              DEFAULT '',
    first_registered    TIMESTAMPTZ       DEFAULT now(),
    first_seen          TIMESTAMPTZ,
    last_seen           TIMESTAMPTZ       DEFAULT now(),
    metadata            JSONB             DEFAULT '{}'::jsonb,
    created_by          TEXT              DEFAULT 'system',
    checker_count       INTEGER           DEFAULT 0,
    updated_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_agents_poller ON agents (poller_id);

CREATE TABLE IF NOT EXISTS checkers (
    checker_id          TEXT              PRIMARY KEY,
    agent_id            TEXT              NOT NULL,
    poller_id           TEXT              NOT NULL,
    checker_kind        TEXT              NOT NULL,
    component_id        TEXT              DEFAULT '',
    registration_source TEXT              DEFAULT 'implicit',
    status              TEXT              DEFAULT 'active',
    spiffe_identity     TEXT              DEFAULT '',
    first_registered    TIMESTAMPTZ       DEFAULT now(),
    first_seen          TIMESTAMPTZ,
    last_seen           TIMESTAMPTZ       DEFAULT now(),
    metadata            JSONB             DEFAULT '{}'::jsonb,
    created_by          TEXT              DEFAULT 'system',
    updated_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_checkers_agent ON checkers (agent_id);
CREATE INDEX IF NOT EXISTS idx_checkers_poller ON checkers (poller_id);

CREATE TABLE IF NOT EXISTS service_registration_events (
    event_id            TEXT              NOT NULL,
    event_type          TEXT              NOT NULL,
    service_id          TEXT              NOT NULL,
    service_type        TEXT              NOT NULL,
    parent_id           TEXT,
    registration_source TEXT,
    actor               TEXT,
    timestamp           TIMESTAMPTZ       NOT NULL DEFAULT now(),
    metadata            JSONB             DEFAULT '{}'::jsonb,
    PRIMARY KEY (event_id, timestamp)
);
SELECT create_hypertable('service_registration_events','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('service_registration_events', INTERVAL '90 days', if_not_exists => TRUE);

-- ================================
-- Poller/service history
-- ================================
CREATE TABLE IF NOT EXISTS poller_history (
    timestamp           TIMESTAMPTZ       NOT NULL,
    poller_id           TEXT              NOT NULL,
    is_healthy          BOOLEAN           NOT NULL,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('poller_history','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('poller_history', INTERVAL '7 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_poller_history_id_time ON poller_history (poller_id, timestamp DESC);

CREATE TABLE IF NOT EXISTS service_status (
    timestamp           TIMESTAMPTZ       NOT NULL,
    poller_id           TEXT              NOT NULL,
    agent_id            TEXT,
    service_name        TEXT              NOT NULL,
    service_type        TEXT,
    available           BOOLEAN           NOT NULL,
    message             TEXT,
    details             TEXT,
    partition           TEXT,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('service_status','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('service_status', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_service_status_identity ON service_status (poller_id, service_name, timestamp DESC);

CREATE TABLE IF NOT EXISTS services (
    timestamp           TIMESTAMPTZ       NOT NULL,
    poller_id           TEXT              NOT NULL,
    agent_id            TEXT,
    service_name        TEXT              NOT NULL,
    service_type        TEXT,
    config              JSONB             DEFAULT '{}'::jsonb,
    partition           TEXT,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
SELECT create_hypertable('services','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('services', INTERVAL '30 days', if_not_exists => TRUE);

-- ================================
-- Edge onboarding
-- ================================
CREATE TABLE IF NOT EXISTS edge_onboarding_packages (
    package_id             UUID             PRIMARY KEY,
    label                  TEXT             NOT NULL,
    component_id           TEXT             DEFAULT '',
    component_type         TEXT             DEFAULT 'poller',
    parent_type            TEXT             DEFAULT '',
    parent_id              TEXT             DEFAULT '',
    poller_id              TEXT,
    site                   TEXT,
    status                 TEXT             DEFAULT 'pending',
    security_mode          TEXT             DEFAULT 'spire',
    downstream_entry_id    TEXT             DEFAULT '',
    downstream_spiffe_id   TEXT             DEFAULT '',
    selectors              TEXT[]           DEFAULT '{}',
    checker_kind           TEXT             DEFAULT '',
    checker_config_json    JSONB            DEFAULT '{}'::jsonb,
    join_token_ciphertext  TEXT,
    join_token_expires_at  TIMESTAMPTZ,
    bundle_ciphertext      TEXT,
    download_token_hash    TEXT,
    download_token_expires_at TIMESTAMPTZ,
    created_by             TEXT             DEFAULT 'system',
    created_at             TIMESTAMPTZ      NOT NULL,
    updated_at             TIMESTAMPTZ      NOT NULL,
    delivered_at           TIMESTAMPTZ,
    activated_at           TIMESTAMPTZ,
    activated_from_ip      TEXT,
    last_seen_spiffe_id    TEXT,
    revoked_at             TIMESTAMPTZ,
    deleted_at             TIMESTAMPTZ,
    deleted_by             TEXT             DEFAULT '',
    deleted_reason         TEXT             DEFAULT '',
    metadata_json          JSONB            DEFAULT '{}'::jsonb,
    kv_revision            BIGINT           DEFAULT 0,
    notes                  TEXT
);
CREATE INDEX IF NOT EXISTS idx_edge_packages_status ON edge_onboarding_packages (status, updated_at DESC);

CREATE TABLE IF NOT EXISTS edge_onboarding_events (
    event_time            TIMESTAMPTZ      NOT NULL,
    package_id            UUID             NOT NULL,
    event_type            TEXT             NOT NULL,
    actor                 TEXT,
    source_ip             TEXT,
    details_json          JSONB            DEFAULT '{}'::jsonb,
    PRIMARY KEY (event_time, package_id)
);
SELECT create_hypertable('edge_onboarding_events','event_time', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('edge_onboarding_events', INTERVAL '365 days', if_not_exists => TRUE);

-- ================================
-- Device capability registry
-- ================================
CREATE TABLE IF NOT EXISTS device_capabilities (
    event_id            TEXT              NOT NULL,
    device_id           TEXT              NOT NULL,
    service_id          TEXT              DEFAULT '',
    service_type        TEXT              DEFAULT '',
    capability          TEXT              NOT NULL,
    state               TEXT              DEFAULT 'unknown',
    enabled             BOOLEAN           DEFAULT TRUE,
    last_checked        TIMESTAMPTZ       DEFAULT now(),
    last_success        TIMESTAMPTZ,
    last_failure        TIMESTAMPTZ,
    failure_reason      TEXT              DEFAULT '',
    metadata            JSONB             DEFAULT '{}'::jsonb,
    recorded_by         TEXT              DEFAULT 'system',
    PRIMARY KEY (event_id, last_checked)
);
SELECT create_hypertable('device_capabilities','last_checked', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('device_capabilities', INTERVAL '90 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_device_capabilities_lookup ON device_capabilities (device_id, capability, service_id, last_checked DESC);

CREATE TABLE IF NOT EXISTS device_capability_registry (
    device_id           TEXT              NOT NULL,
    capability          TEXT              NOT NULL,
    service_id          TEXT              DEFAULT '',
    service_type        TEXT              DEFAULT '',
    state               TEXT              DEFAULT 'unknown',
    enabled             BOOLEAN           DEFAULT TRUE,
    last_checked        TIMESTAMPTZ,
    last_success        TIMESTAMPTZ,
    last_failure        TIMESTAMPTZ,
    failure_reason      TEXT              DEFAULT '',
    metadata            JSONB             DEFAULT '{}'::jsonb,
    recorded_by         TEXT              DEFAULT 'system',
    updated_at          TIMESTAMPTZ       NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, capability, service_id)
);

-- ================================
-- CloudEvents + rperf + users
-- ================================
CREATE TABLE IF NOT EXISTS events (
    event_timestamp    TIMESTAMPTZ   NOT NULL,
    specversion        TEXT,
    id                 TEXT          NOT NULL,
    source             TEXT,
    type               TEXT,
    datacontenttype    TEXT,
    subject            TEXT,
    remote_addr        TEXT,
    host               TEXT,
    level              INTEGER,
    severity           TEXT,
    short_message      TEXT,
    version            TEXT,
    raw_data           TEXT,
    created_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (event_timestamp, id)
);
SELECT create_hypertable('events','event_timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('events', INTERVAL '3 days', if_not_exists => TRUE);
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_id_unique ON events (id, event_timestamp);
CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events (event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_events_subject ON events (subject);

CREATE TABLE IF NOT EXISTS rperf_metrics (
    timestamp      TIMESTAMPTZ   NOT NULL,
    poller_id      TEXT          NOT NULL,
    service_name   TEXT          NOT NULL,
    message        TEXT,
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);
SELECT create_hypertable('rperf_metrics','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('rperf_metrics', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_rperf_metrics_poller_time ON rperf_metrics (poller_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_rperf_metrics_service ON rperf_metrics (service_name);

CREATE TABLE IF NOT EXISTS users (
    id             TEXT           PRIMARY KEY,
    username       TEXT           NOT NULL,
    email          TEXT           NOT NULL,
    provider       TEXT           NOT NULL DEFAULT 'local',
    password_hash  TEXT           NOT NULL DEFAULT '',
    created_at     TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ    NOT NULL DEFAULT now(),
    is_active      BOOLEAN        NOT NULL DEFAULT TRUE,
    roles          TEXT[]         NOT NULL DEFAULT '{}'::text[]
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_lower ON users ((lower(email)));
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username_lower ON users ((lower(username)));

-- ================================
-- OTEL observability tables
-- ================================
CREATE TABLE IF NOT EXISTS logs (
    timestamp           TIMESTAMPTZ   NOT NULL,
    trace_id            TEXT,
    span_id             TEXT,
    severity_text       TEXT,
    severity_number     INTEGER,
    body                TEXT,
    service_name        TEXT,
    service_version     TEXT,
    service_instance    TEXT,
    scope_name          TEXT,
    scope_version       TEXT,
    attributes          TEXT,
    resource_attributes TEXT,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (timestamp, trace_id, span_id)
);
SELECT create_hypertable('logs','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('logs', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_logs_service_time ON logs (service_name, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_logs_trace_id ON logs (trace_id);

CREATE TABLE IF NOT EXISTS otel_metrics (
    timestamp           TIMESTAMPTZ       NOT NULL,
    trace_id            TEXT,
    span_id             TEXT,
    service_name        TEXT,
    span_name           TEXT,
    span_kind           TEXT,
    duration_ms         DOUBLE PRECISION,
    duration_seconds    DOUBLE PRECISION,
    metric_type         TEXT,
    http_method         TEXT,
    http_route          TEXT,
    http_status_code    TEXT,
    grpc_service        TEXT,
    grpc_method         TEXT,
    grpc_status_code    TEXT,
    is_slow             BOOLEAN,
    component           TEXT,
    level               TEXT,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now(),
    PRIMARY KEY (timestamp, span_name, service_name, span_id)
);
SELECT create_hypertable('otel_metrics','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('otel_metrics', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_otel_metrics_service_time ON otel_metrics (service_name, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_otel_metrics_component ON otel_metrics (component);

CREATE TABLE IF NOT EXISTS otel_traces (
    timestamp           TIMESTAMPTZ   NOT NULL,
    trace_id            TEXT,
    span_id             TEXT,
    parent_span_id      TEXT,
    name                TEXT,
    kind                INTEGER,
    start_time_unix_nano BIGINT,
    end_time_unix_nano  BIGINT,
    service_name        TEXT,
    service_version     TEXT,
    service_instance    TEXT,
    scope_name          TEXT,
    scope_version       TEXT,
    status_code         INTEGER,
    status_message      TEXT,
    attributes          TEXT,
    resource_attributes TEXT,
    events              TEXT,
    links               TEXT,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (timestamp, trace_id, span_id)
);
SELECT create_hypertable('otel_traces','timestamp', if_not_exists => TRUE);
-- DISABLED: SELECT add_retention_policy('otel_traces', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_otel_traces_trace_id ON otel_traces (trace_id);
CREATE INDEX IF NOT EXISTS idx_otel_traces_service_time ON otel_traces (service_name, timestamp DESC);

-- ================================
-- Identity & reconciliation schema
-- ================================

-- Subnet policies drive promotion/reaper rules per CIDR
CREATE TABLE IF NOT EXISTS subnet_policies (
    subnet_id        UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    cidr             CIDR            NOT NULL,
    classification   TEXT            NOT NULL DEFAULT 'dynamic',
    promotion_rules  JSONB           NOT NULL DEFAULT '{}'::jsonb,
    reaper_profile   TEXT            NOT NULL DEFAULT 'default',
    allow_ip_as_id   BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ     NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_subnet_policies_cidr ON subnet_policies (cidr);

-- Fingerprints summarize OS/port signals for correlation
CREATE TABLE IF NOT EXISTS fingerprints (
    fingerprint_id   UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    hash             TEXT            NOT NULL,
    os_family        TEXT,
    ports            JSONB,
    host_label       TEXT,
    first_seen       TIMESTAMPTZ     NOT NULL DEFAULT now(),
    last_seen        TIMESTAMPTZ     NOT NULL DEFAULT now(),
    metadata         JSONB           NOT NULL DEFAULT '{}'::jsonb
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_fingerprints_hash ON fingerprints (hash);
CREATE INDEX IF NOT EXISTS idx_fingerprints_host_label ON fingerprints (host_label);

-- Network sightings are low-confidence observations prior to promotion
CREATE TABLE IF NOT EXISTS network_sightings (
    sighting_id      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    partition        TEXT            NOT NULL,
    ip               TEXT            NOT NULL,
    subnet_id        UUID            REFERENCES subnet_policies(subnet_id) ON DELETE SET NULL,
    source           TEXT            NOT NULL,
    status           TEXT            NOT NULL DEFAULT 'active',
    first_seen       TIMESTAMPTZ     NOT NULL DEFAULT now(),
    last_seen        TIMESTAMPTZ     NOT NULL DEFAULT now(),
    ttl_expires_at   TIMESTAMPTZ,
    fingerprint_id   UUID            REFERENCES fingerprints(fingerprint_id) ON DELETE SET NULL,
    metadata         JSONB           NOT NULL DEFAULT '{}'::jsonb,
    created_at       TIMESTAMPTZ     NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_network_sightings_active_per_ip
ON network_sightings (partition, ip)
WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_network_sightings_subnet_status_expiry
ON network_sightings (subnet_id, status, ttl_expires_at);
CREATE INDEX IF NOT EXISTS idx_network_sightings_fingerprint
ON network_sightings (fingerprint_id)
WHERE fingerprint_id IS NOT NULL;

-- Device identifiers - CORE TABLE FOR DIRE
-- Unique constraint on (identifier_type, identifier_value, partition) prevents duplicates
CREATE TABLE IF NOT EXISTS device_identifiers (
    id               SERIAL          PRIMARY KEY,
    device_id        TEXT            NOT NULL,
    identifier_type  TEXT            NOT NULL,  -- 'armis_device_id', 'mac', 'netbox_device_id', 'integration_id'
    identifier_value TEXT            NOT NULL,
    partition        TEXT            NOT NULL DEFAULT 'default',
    confidence       TEXT            NOT NULL DEFAULT 'strong',
    source           TEXT,
    first_seen       TIMESTAMPTZ     NOT NULL DEFAULT now(),
    last_seen        TIMESTAMPTZ     NOT NULL DEFAULT now(),
    verified         BOOLEAN         NOT NULL DEFAULT FALSE,
    metadata         JSONB           NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (identifier_type, identifier_value, partition)
);
CREATE INDEX IF NOT EXISTS idx_device_identifiers_device ON device_identifiers(device_id);
CREATE INDEX IF NOT EXISTS idx_device_identifiers_lookup ON device_identifiers(identifier_type, identifier_value);

-- Audit trail for sighting lifecycle events
CREATE TABLE IF NOT EXISTS sighting_events (
    event_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    sighting_id      UUID            NOT NULL REFERENCES network_sightings(sighting_id) ON DELETE CASCADE,
    device_id        TEXT,
    event_type       TEXT            NOT NULL,
    actor            TEXT            NOT NULL DEFAULT 'system',
    details          JSONB           NOT NULL DEFAULT '{}'::jsonb,
    created_at       TIMESTAMPTZ     NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sighting_events_sighting ON sighting_events (sighting_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sighting_events_device ON sighting_events (device_id, created_at DESC);

-- Merge audit for device reconciliations (kept for audit trail only)
CREATE TABLE IF NOT EXISTS merge_audit (
    event_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    from_device_id   TEXT            NOT NULL,
    to_device_id     TEXT            NOT NULL,
    reason           TEXT,
    confidence_score NUMERIC,
    source           TEXT,
    details          JSONB           NOT NULL DEFAULT '{}'::jsonb,
    created_at       TIMESTAMPTZ     NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_merge_audit_to_device ON merge_audit (to_device_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_merge_audit_from_device ON merge_audit (from_device_id, created_at DESC);

-- ================================
-- Role grants
-- ================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spire') THEN
        GRANT USAGE ON SCHEMA public TO spire;
        GRANT SELECT ON TABLE logs TO spire;
        GRANT SELECT ON TABLE otel_metrics TO spire;
        GRANT SELECT ON TABLE otel_traces TO spire;
    END IF;
END $$;

-- ================================
-- Apache AGE graph bootstrap
-- ================================
DO $$
BEGIN
    -- Try to create AGE extension (may not be available in all environments)
    BEGIN
        CREATE EXTENSION IF NOT EXISTS age;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'AGE extension not available: %', SQLERRM;
        RETURN;
    END;
END $$;

-- AGE graph setup (only runs if AGE is available)
DO $$
DECLARE
    graph_oid oid;
BEGIN
    -- Check if AGE is available
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age') THEN
        RETURN;
    END IF;

    -- Set search path for AGE
    PERFORM set_config('search_path', 'ag_catalog, public', false);

    -- Create the graph if missing
    SELECT graphid INTO graph_oid FROM ag_catalog.ag_graph WHERE name = 'serviceradar';
    IF graph_oid IS NULL THEN
        PERFORM ag_catalog.create_graph('serviceradar');
        SELECT graphid INTO graph_oid FROM ag_catalog.ag_graph WHERE name = 'serviceradar';
    END IF;

    -- Vertex labels
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'Device' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Device');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'Service' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Service');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'Collector' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Collector');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'Interface' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Interface');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'Capability' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Capability');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'CheckerDefinition' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'CheckerDefinition');
    END IF;

    -- Edge labels
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'HOSTS_SERVICE' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'HOSTS_SERVICE');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'RUNS_CHECKER' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'RUNS_CHECKER');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'TARGETS' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'TARGETS');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'HAS_INTERFACE' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'HAS_INTERFACE');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'CONNECTS_TO' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'CONNECTS_TO');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'PROVIDES_CAPABILITY' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'PROVIDES_CAPABILITY');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'REPORTED_BY' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'REPORTED_BY');
    END IF;

    -- Property indexes
    IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ag_catalog'::regnamespace AND proname = 'create_property_index') THEN
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Device', 'id');
        EXCEPTION WHEN duplicate_table OR duplicate_object THEN NULL;
        END;
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Service', 'id');
        EXCEPTION WHEN duplicate_table OR duplicate_object THEN NULL;
        END;
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Collector', 'id');
        EXCEPTION WHEN duplicate_table OR duplicate_object THEN NULL;
        END;
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Interface', 'id');
        EXCEPTION WHEN duplicate_table OR duplicate_object THEN NULL;
        END;
    END IF;

    -- Grant AGE access to serviceradar role
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar') THEN
        EXECUTE 'GRANT USAGE ON SCHEMA ag_catalog TO serviceradar';
        EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO serviceradar';
        EXECUTE 'GRANT USAGE ON SCHEMA serviceradar TO serviceradar';
        EXECUTE 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA serviceradar TO serviceradar';
        EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA serviceradar GRANT ALL ON TABLES TO serviceradar';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'AGE graph setup skipped: %', SQLERRM;
END $$;

-- AGE sequence privileges
DO $$
DECLARE
    seq record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar') THEN
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'serviceradar') THEN
        RETURN;
    END IF;

    FOR seq IN
        SELECT schemaname, sequencename
        FROM pg_sequences
        WHERE schemaname = 'serviceradar'
    LOOP
        EXECUTE format(
            'GRANT USAGE, SELECT, UPDATE ON SEQUENCE %I.%I TO serviceradar',
            seq.schemaname, seq.sequencename
        );
    END LOOP;

    ALTER DEFAULT PRIVILEGES IN SCHEMA serviceradar
        GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO serviceradar;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Sequence grants skipped: %', SQLERRM;
END $$;

-- AGE device neighborhood function
CREATE OR REPLACE FUNCTION public.age_device_neighborhood(
    p_device_id text,
    p_collector_owned_only boolean DEFAULT false,
    p_include_topology boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    cypher_sql text;
    cypher_result ag_catalog.agtype;
    include_topology text := CASE WHEN coalesce(p_include_topology, true) THEN 'true' ELSE 'false' END;
    collector_only text := CASE WHEN coalesce(p_collector_owned_only, false) THEN 'true' ELSE 'false' END;
BEGIN
    PERFORM set_config('search_path', 'ag_catalog,pg_catalog,"$user",public', false);

    cypher_sql := format($cypher$
        WITH %s::boolean AS include_topology, %s::boolean AS collector_only
        MATCH (c:Collector {id: %L})
        OPTIONAL MATCH (c)-[:REPORTED_BY]->(parentCol:Collector)
        OPTIONAL MATCH (devAlias:Device {id: %L})-[:REPORTED_BY]->(parentFromAlias:Collector)
        OPTIONAL MATCH (childCol:Collector)-[:REPORTED_BY]->(c)
        OPTIONAL MATCH (childDev:Device)-[:REPORTED_BY]->(c)
            WHERE childDev.id STARTS WITH 'serviceradar:'
        WITH c, include_topology,
             collect(DISTINCT parentCol) + collect(DISTINCT parentFromAlias) AS parent_collectors,
             collect(DISTINCT childCol) AS child_collectors,
             collect(DISTINCT childDev.id) AS child_dev_ids
        WITH c, include_topology, parent_collectors, child_collectors,
             CASE WHEN size(child_dev_ids) = 0 THEN [NULL] ELSE child_dev_ids END AS child_dev_ids_safe
        UNWIND child_dev_ids_safe AS child_dev_id
        OPTIONAL MATCH (aliasCol:Collector {id: child_dev_id})
        WITH c, include_topology,
             parent_collectors,
             child_collectors,
             collect(DISTINCT aliasCol) AS alias_child_collectors
        WITH c, include_topology,
             [col IN parent_collectors WHERE col IS NOT NULL] AS parent_collectors,
             [col IN (child_collectors + alias_child_collectors) WHERE col IS NOT NULL] AS child_collectors,
             [c] + [col IN (child_collectors + alias_child_collectors) WHERE col IS NOT NULL | col] AS host_collectors
        UNWIND host_collectors AS host_col
        OPTIONAL MATCH (host_col)-[:HOSTS_SERVICE]->(svc:Service)
        OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
        OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
        OPTIONAL MATCH (reported:Device)-[:REPORTED_BY]->(host_col)
        WITH c, include_topology, parent_collectors, child_collectors,
             collect(DISTINCT CASE WHEN svc IS NOT NULL THEN {service: properties(svc), collector_id: host_col.id, collector_owned: true} ELSE NULL END) AS services_output_raw,
             collect(DISTINCT t) AS service_targets,
             collect(DISTINCT svcCap) AS service_caps,
             collect(DISTINCT reported) AS reported_devices
        WITH c, include_topology, parent_collectors, child_collectors, services_output_raw, service_targets, service_caps, reported_devices,
             CASE WHEN size(service_targets + reported_devices) = 0 THEN [NULL] ELSE service_targets + reported_devices END AS combined_targets
        UNWIND combined_targets AS tgt
        WITH c, include_topology, parent_collectors, child_collectors, services_output_raw, service_caps,
             collect(DISTINCT tgt) AS all_targets
        RETURN {
            device: properties(c),
            collectors: [col IN (parent_collectors + child_collectors) WHERE col IS NOT NULL | properties(col)],
            services: [s IN services_output_raw WHERE s IS NOT NULL | s],
            targets: [tgt IN all_targets WHERE tgt IS NOT NULL | properties(tgt)],
            interfaces: [],
            peer_interfaces: [],
            device_capabilities: [],
            service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
        } AS result
    $cypher$, include_topology, collector_only, p_device_id, p_device_id);

    EXECUTE 'SELECT result FROM ag_catalog.cypher(''serviceradar'', ' ||
            chr(36) || chr(36) || cypher_sql || chr(36) || chr(36) ||
            ') AS (result ag_catalog.agtype)'
    INTO cypher_result;

    IF cypher_result IS NULL OR cypher_result::text = 'null' THEN
        cypher_sql := format($cypher$
            WITH %s::boolean AS include_topology, %s::boolean AS collector_only
            MATCH (d:Device {id: %L})
            OPTIONAL MATCH (d)-[:REPORTED_BY]->(col:Collector)
            OPTIONAL MATCH (col)-[:HOSTS_SERVICE]->(svc:Service)
            OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
            OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
            OPTIONAL MATCH (d)-[:PROVIDES_CAPABILITY]->(dcap:Capability)
            OPTIONAL MATCH (d)-[:HAS_INTERFACE]->(iface:Interface)
            OPTIONAL MATCH (iface)-[:CONNECTS_TO]->(peer:Interface)
            WITH d, include_topology, collector_only,
                 collect(DISTINCT col) AS collectors,
                 collect(DISTINCT CASE WHEN svc IS NOT NULL AND t IS NOT NULL AND t.id = d.id AND col IS NOT NULL THEN {
                     service: properties(svc),
                     collector_id: col.id,
                     collector_owned: col IS NOT NULL
                 } ELSE NULL END) AS services_output_raw,
                 collect(DISTINCT CASE WHEN svc IS NOT NULL AND t IS NOT NULL AND t.id = d.id AND col IS NOT NULL THEN col ELSE NULL END) AS host_collectors_raw,
                 collect(DISTINCT CASE WHEN t IS NOT NULL AND t.id <> d.id THEN properties(t) ELSE NULL END) AS target_props_raw,
                 collect(DISTINCT iface) AS interfaces,
                 collect(DISTINCT peer) AS peers,
                 collect(DISTINCT dcap) AS device_caps,
                 collect(DISTINCT svcCap) AS service_caps
            WITH d, include_topology, collector_only, collectors, target_props_raw, interfaces, peers, device_caps, service_caps,
                 [c IN host_collectors_raw WHERE c IS NOT NULL] AS host_collectors,
                 [s IN services_output_raw WHERE s IS NOT NULL] AS services_output
            WITH d, include_topology, collector_only, collectors, services_output, target_props_raw, interfaces, peers, device_caps, service_caps, host_collectors,
                 CASE WHEN size(host_collectors) > 0 THEN host_collectors ELSE collectors END AS collector_list,
                 (size(host_collectors) > 0 OR size([c IN collectors WHERE c IS NOT NULL]) > 0) AS has_collector,
                 [tgt IN target_props_raw WHERE tgt IS NOT NULL | tgt] AS target_props
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peers, device_caps, service_caps, has_collector,
                 CASE WHEN size(collector_list) = 0 THEN [NULL] ELSE collector_list END AS collector_list_safe
            UNWIND collector_list_safe AS base_col
            OPTIONAL MATCH (parentCol:Collector)<-[:REPORTED_BY]-(base_col)
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peers, device_caps, service_caps, has_collector,
                 collect(DISTINCT base_col) AS collector_list_dedup,
                 collect(DISTINCT parentCol) AS parent_collectors
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peers, device_caps, service_caps,
                 collector_list_dedup + parent_collectors AS combined_collectors,
                 (has_collector OR size([p IN parent_collectors WHERE p IS NOT NULL]) > 0) AS has_any_collector
            WHERE NOT collector_only OR has_any_collector
            RETURN {
                device: properties(d),
                collectors: [c IN combined_collectors WHERE c IS NOT NULL | properties(c)],
                services: services_output,
                targets: target_props,
                interfaces: CASE WHEN include_topology THEN [i IN interfaces WHERE i IS NOT NULL | properties(i)] ELSE [] END,
                peer_interfaces: CASE WHEN include_topology THEN [p IN peers WHERE p IS NOT NULL | properties(p)] ELSE [] END,
                device_capabilities: [cap IN device_caps WHERE cap IS NOT NULL | properties(cap)],
                service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
            } AS result
        $cypher$, include_topology, collector_only, p_device_id);

        EXECUTE 'SELECT result FROM ag_catalog.cypher(''serviceradar'', ' ||
                chr(36) || chr(36) || cypher_sql || chr(36) || chr(36) ||
                ') AS (result ag_catalog.agtype)'
        INTO cypher_result;
    END IF;

    IF cypher_result IS NULL OR cypher_result::text = 'null' THEN
        cypher_sql := format($cypher$
            WITH %s::boolean AS include_topology, %s::boolean AS collector_only
            MATCH (svc:Service {id: %L})
            OPTIONAL MATCH (col:Collector)-[:HOSTS_SERVICE]->(svc)
            OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
            OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
            WITH svc, include_topology, collector_only,
                 collect(DISTINCT col) AS collectors,
                 collect(DISTINCT t) AS targets,
                 collect(DISTINCT svcCap) AS service_caps
            WITH svc, include_topology, collector_only,
                 CASE WHEN size(collectors) = 0 THEN [NULL] ELSE collectors END AS collectors_list,
                 CASE WHEN size(targets) = 0 THEN [NULL] ELSE targets END AS targets_list,
                 service_caps
            UNWIND collectors_list AS base_col
            OPTIONAL MATCH (parentCol:Collector)<-[:REPORTED_BY]-(base_col)
            UNWIND targets_list AS tgt
            WITH svc, include_topology, collector_only, service_caps,
                 collect(DISTINCT base_col) AS collectors,
                 collect(DISTINCT parentCol) AS parent_collectors,
                 collect(DISTINCT tgt) AS targets_flat
            WITH svc, include_topology, collector_only,
                 collectors + parent_collectors AS combined_collectors,
                 targets_flat,
                 service_caps,
                 size([c IN (collectors + parent_collectors) WHERE c IS NOT NULL]) > 0 AS has_collector
            WHERE NOT collector_only OR has_collector
            RETURN {
                device: properties(svc),
                collectors: [c IN combined_collectors WHERE c IS NOT NULL | properties(c)],
                services: [{
                    service: properties(svc),
                    collector_id: CASE WHEN size([c IN combined_collectors WHERE c IS NOT NULL]) > 0 THEN (combined_collectors[0].id) ELSE NULL END,
                    collector_owned: size([c IN combined_collectors WHERE c IS NOT NULL]) > 0
                }],
                targets: [tgt IN targets_flat WHERE tgt IS NOT NULL | properties(tgt)],
                interfaces: [],
                peer_interfaces: [],
                device_capabilities: [],
                service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
            } AS result
        $cypher$, include_topology, collector_only, p_device_id);

        EXECUTE 'SELECT result FROM ag_catalog.cypher(''serviceradar'', ' ||
                chr(36) || chr(36) || cypher_sql || chr(36) || chr(36) ||
                ') AS (result ag_catalog.agtype)'
        INTO cypher_result;
    END IF;

    RETURN (cypher_result::text)::jsonb;
EXCEPTION
    WHEN undefined_function THEN
        RETURN NULL;
END;
$$;
