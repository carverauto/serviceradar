-- Timescale schema for CNPG-backed telemetry and registry storage
CREATE EXTENSION IF NOT EXISTS timescaledb;

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
SELECT add_retention_policy('timeseries_metrics', INTERVAL '3 days', if_not_exists => TRUE);
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
SELECT add_retention_policy('cpu_metrics', INTERVAL '3 days', if_not_exists => TRUE);
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
SELECT add_retention_policy('cpu_cluster_metrics', INTERVAL '3 days', if_not_exists => TRUE);

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
SELECT add_retention_policy('disk_metrics', INTERVAL '3 days', if_not_exists => TRUE);

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
SELECT add_retention_policy('memory_metrics', INTERVAL '3 days', if_not_exists => TRUE);

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
SELECT add_retention_policy('process_metrics', INTERVAL '3 days', if_not_exists => TRUE);

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
SELECT add_retention_policy('netflow_metrics', INTERVAL '3 days', if_not_exists => TRUE);

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
SELECT add_retention_policy('sweep_host_states', INTERVAL '3 days', if_not_exists => TRUE);

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
SELECT add_retention_policy('discovered_interfaces', INTERVAL '3 days', if_not_exists => TRUE);

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
SELECT add_retention_policy('topology_discovery_events', INTERVAL '3 days', if_not_exists => TRUE);

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
SELECT add_retention_policy('device_updates', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_device_updates_device_time ON device_updates (device_id, observed_at DESC);

CREATE TABLE IF NOT EXISTS unified_devices (
    device_id           TEXT              PRIMARY KEY,
    ip                  TEXT,
    poller_id           TEXT,
    agent_id            TEXT,
    hostname            TEXT,
    mac                 TEXT,
    discovery_sources   TEXT[],
    is_available        BOOLEAN,
    first_seen          TIMESTAMPTZ,
    last_seen           TIMESTAMPTZ,
    metadata            JSONB,
    device_type         TEXT              NOT NULL DEFAULT 'network_device',
    service_type        TEXT,
    service_status      TEXT,
    last_heartbeat      TIMESTAMPTZ,
    os_info             TEXT,
    version_info        TEXT,
    updated_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_unified_devices_ip ON unified_devices (ip);
CREATE INDEX IF NOT EXISTS idx_unified_devices_last_seen ON unified_devices (last_seen);

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
SELECT add_retention_policy('service_registration_events', INTERVAL '90 days', if_not_exists => TRUE);

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
SELECT add_retention_policy('poller_history', INTERVAL '7 days', if_not_exists => TRUE);
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
SELECT add_retention_policy('service_status', INTERVAL '3 days', if_not_exists => TRUE);
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
SELECT add_retention_policy('services', INTERVAL '30 days', if_not_exists => TRUE);

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
SELECT add_retention_policy('edge_onboarding_events', INTERVAL '365 days', if_not_exists => TRUE);

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
SELECT add_retention_policy('device_capabilities', INTERVAL '90 days', if_not_exists => TRUE);
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
