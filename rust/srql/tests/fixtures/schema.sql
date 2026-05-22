-- Deterministic CNPG schema subset for SRQL API tests.
-- The harness drops tables before creation so each test starts cleanly.

DROP TABLE IF EXISTS device_agent_availability;
DROP TABLE IF EXISTS ocsf_devices;

CREATE TABLE ocsf_devices (
    -- OCSF Core Identity
    uid                 TEXT        PRIMARY KEY,
    type_id             INT         NOT NULL DEFAULT 0,
    type                TEXT,
    name                TEXT,
    hostname            TEXT,
    ip                  TEXT,
    mac                 TEXT,
    -- OCSF Extended Identity
    uid_alt             TEXT,
    vendor_name         TEXT,
    model               TEXT,
    domain              TEXT,
    zone                TEXT,
    subnet_uid          TEXT,
    vlan_uid            TEXT,
    region              TEXT,
    -- OCSF Temporal
    first_seen_time     TIMESTAMPTZ,
    last_seen_time      TIMESTAMPTZ,
    created_time        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    modified_time       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- OCSF Risk and Compliance
    risk_level_id       INT,
    risk_level          TEXT,
    risk_score          INT,
    is_managed          BOOLEAN,
    is_compliant        BOOLEAN,
    is_trusted          BOOLEAN,
    -- OCSF Nested Objects (JSONB)
    os                  JSONB,
    hw_info             JSONB,
    network_interfaces  JSONB,
    owner               JSONB,
    org                 JSONB,
    groups              JSONB,
    agent_list          JSONB,
    -- ServiceRadar-specific fields
    gateway_id           TEXT,
    agent_id            TEXT,
    availability_source_agent_id TEXT,
    discovery_sources   TEXT[],
    is_available        BOOLEAN,
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    metadata            JSONB,
    deleted_at          TIMESTAMPTZ,
    deleted_by          TEXT,
    deleted_reason      TEXT
);

CREATE TABLE device_agent_availability (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    device_uid          TEXT        NOT NULL REFERENCES ocsf_devices(uid) ON DELETE CASCADE,
    agent_id            TEXT        NOT NULL,
    agent_name          TEXT,
    is_available        BOOLEAN     NOT NULL,
    checked_at          TIMESTAMPTZ NOT NULL,
    response_time_ms    BIGINT,
    open_ports          INT[]       NOT NULL DEFAULT '{}',
    sweep_modes_results JSONB       NOT NULL DEFAULT '{}',
    sweep_group_id      UUID,
    execution_id        UUID,
    metadata            JSONB       NOT NULL DEFAULT '{}',
    inserted_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (device_uid, agent_id)
);

DROP TABLE IF EXISTS gateways;
CREATE TABLE gateways (
    gateway_id           TEXT        PRIMARY KEY,
    component_id        TEXT,
    registration_source TEXT,
    status              TEXT,
    spiffe_identity     TEXT,
    first_registered    TIMESTAMPTZ,
    first_seen          TIMESTAMPTZ,
    last_seen           TIMESTAMPTZ,
    metadata            JSONB,
    created_by          TEXT,
    is_healthy          BOOLEAN,
    agent_count         INT,
    checker_count       INT,
    updated_at          TIMESTAMPTZ,
    partition_id        UUID
);

DROP TABLE IF EXISTS events;
CREATE TABLE events (
    event_timestamp TIMESTAMPTZ NOT NULL,
    specversion     TEXT,
    id              TEXT        NOT NULL,
    source          TEXT,
    type            TEXT,
    datacontenttype TEXT,
    subject         TEXT,
    remote_addr     TEXT,
    host            TEXT,
    level           INT,
    severity        TEXT,
    short_message   TEXT,
    version         TEXT,
    raw_data        TEXT,
    created_at      TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (event_timestamp, id)
);

DROP TABLE IF EXISTS ocsf_events;
CREATE TABLE ocsf_events (
    time          TIMESTAMPTZ NOT NULL,
    id            UUID        NOT NULL,
    class_uid     INT         NOT NULL,
    category_uid  INT         NOT NULL,
    type_uid      INT         NOT NULL,
    activity_id   INT         NOT NULL,
    activity_name TEXT,
    severity_id   INT,
    severity      TEXT,
    message       TEXT,
    status_id     INT,
    status        TEXT,
    status_code   TEXT,
    status_detail TEXT,
    metadata      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    observables   JSONB       NOT NULL DEFAULT '[]'::jsonb,
    trace_id      TEXT,
    span_id       TEXT,
    actor         JSONB       NOT NULL DEFAULT '{}'::jsonb,
    device        JSONB       NOT NULL DEFAULT '{}'::jsonb,
    src_endpoint  JSONB       NOT NULL DEFAULT '{}'::jsonb,
    dst_endpoint  JSONB       NOT NULL DEFAULT '{}'::jsonb,
    log_name      TEXT,
    log_provider  TEXT,
    log_level     TEXT,
    log_version   TEXT,
    unmapped      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    raw_data      TEXT,
    created_at    TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (time, id)
);

DROP TABLE IF EXISTS logs;
CREATE TABLE logs (
    timestamp           TIMESTAMPTZ NOT NULL,
    observed_timestamp  TIMESTAMPTZ,
    id                  UUID NOT NULL DEFAULT gen_random_uuid(),
    trace_id            TEXT,
    span_id             TEXT,
    trace_flags         INT,
    severity_text       TEXT,
    severity_number     INT,
    body                TEXT,
    event_name          TEXT,
    source              TEXT,
    service_name        TEXT,
    service_version     TEXT,
    service_instance    TEXT,
    scope_name          TEXT,
    scope_version       TEXT,
    scope_attributes    TEXT,
    attributes          TEXT,
    resource_attributes TEXT,
    created_at          TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, id)
);

DROP TABLE IF EXISTS service_status;
DROP TABLE IF EXISTS latest_check_states;
DROP TABLE IF EXISTS check_instances;
DROP TABLE IF EXISTS monitoring_bindings;
DROP TABLE IF EXISTS service_group_memberships;
DROP TABLE IF EXISTS service_groups;
DROP TABLE IF EXISTS monitored_services;
CREATE TABLE service_status (
    timestamp    TIMESTAMPTZ NOT NULL,
    gateway_id    TEXT        NOT NULL,
    agent_id     TEXT,
    service_id   UUID,
    service_name TEXT        NOT NULL,
    service_type TEXT,
    available    BOOLEAN     NOT NULL,
    message      TEXT,
    details      TEXT,
    partition    TEXT,
    created_at   TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, gateway_id, service_name)
);

CREATE TABLE monitored_services (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    service_key   TEXT        NOT NULL UNIQUE,
    display_name  TEXT        NOT NULL,
    description   TEXT,
    service_kind  TEXT        NOT NULL,
    protocol      TEXT,
    endpoint_url  TEXT,
    host          TEXT,
    port          BIGINT,
    path          TEXT,
    device_uid    TEXT,
    database_name TEXT,
    owner         TEXT,
    status        TEXT        NOT NULL DEFAULT 'active',
    source        TEXT        NOT NULL DEFAULT 'manual',
    tags          JSONB       NOT NULL DEFAULT '{}'::jsonb,
    metadata      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    inserted_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE service_groups (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name           TEXT        NOT NULL,
    slug           TEXT        NOT NULL UNIQUE,
    description    TEXT,
    selection_mode TEXT        NOT NULL DEFAULT 'explicit',
    srql_query     TEXT,
    status         TEXT        NOT NULL DEFAULT 'active',
    tags           JSONB       NOT NULL DEFAULT '{}'::jsonb,
    metadata       JSONB       NOT NULL DEFAULT '{}'::jsonb,
    inserted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE service_group_memberships (
    id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    service_group_id     UUID        NOT NULL REFERENCES service_groups(id) ON DELETE CASCADE,
    monitored_service_id UUID        NOT NULL REFERENCES monitored_services(id) ON DELETE CASCADE,
    source               TEXT        NOT NULL DEFAULT 'explicit',
    metadata             JSONB       NOT NULL DEFAULT '{}'::jsonb,
    inserted_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (service_group_id, monitored_service_id)
);

CREATE TABLE monitoring_bindings (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name                TEXT        NOT NULL,
    descriptor_id       TEXT        NOT NULL,
    descriptor_version  TEXT        NOT NULL DEFAULT '1.0.0',
    capability_kind     TEXT        NOT NULL DEFAULT 'plugin',
    plugin_package_id   UUID,
    target_set_type     TEXT        NOT NULL,
    service_group_id    UUID        REFERENCES service_groups(id) ON DELETE SET NULL,
    target_query        TEXT,
    target_filters      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    agent_scope_type    TEXT        NOT NULL DEFAULT 'any',
    agent_scope_value   TEXT,
    interval_seconds    BIGINT      NOT NULL DEFAULT 60,
    timeout_seconds     BIGINT      NOT NULL DEFAULT 10,
    credential_policy   JSONB       NOT NULL DEFAULT '{}'::jsonb,
    threshold_policy    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    event_policy        JSONB       NOT NULL DEFAULT '{}'::jsonb,
    alert_policy        JSONB       NOT NULL DEFAULT '{}'::jsonb,
    status              TEXT        NOT NULL DEFAULT 'active',
    metadata            JSONB       NOT NULL DEFAULT '{}'::jsonb,
    inserted_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE check_instances (
    id                         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    check_key                  TEXT        NOT NULL UNIQUE,
    monitoring_binding_id      UUID        REFERENCES monitoring_bindings(id) ON DELETE SET NULL,
    monitored_service_id       UUID        REFERENCES monitored_services(id) ON DELETE SET NULL,
    device_uid                 TEXT,
    descriptor_id              TEXT        NOT NULL,
    descriptor_version         TEXT        NOT NULL DEFAULT '1.0.0',
    capability_kind            TEXT        NOT NULL DEFAULT 'plugin',
    plugin_package_id          UUID,
    vantage_kind               TEXT        NOT NULL DEFAULT 'agent',
    vantage_id                 TEXT,
    agent_id                   TEXT,
    target_snapshot            JSONB       NOT NULL DEFAULT '{}'::jsonb,
    credential_policy_snapshot JSONB       NOT NULL DEFAULT '{}'::jsonb,
    event_policy_snapshot      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    status                     TEXT        NOT NULL DEFAULT 'active',
    last_materialized_at       TIMESTAMPTZ,
    metadata                   JSONB       NOT NULL DEFAULT '{}'::jsonb,
    inserted_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE latest_check_states (
    id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    check_instance_id     UUID        NOT NULL REFERENCES check_instances(id) ON DELETE CASCADE,
    monitored_service_id  UUID        REFERENCES monitored_services(id) ON DELETE SET NULL,
    monitoring_binding_id UUID        REFERENCES monitoring_bindings(id) ON DELETE SET NULL,
    device_uid            TEXT,
    agent_id              TEXT,
    vantage_kind          TEXT        NOT NULL DEFAULT 'agent',
    vantage_id            TEXT,
    status                TEXT        NOT NULL DEFAULT 'unknown',
    previous_status       TEXT,
    status_changed_at     TIMESTAMPTZ,
    last_observed_at      TIMESTAMPTZ NOT NULL,
    response_time_ms      BIGINT,
    summary               TEXT,
    details               JSONB       NOT NULL DEFAULT '{}'::jsonb,
    metrics               JSONB       NOT NULL DEFAULT '{}'::jsonb,
    consecutive_failures  BIGINT      NOT NULL DEFAULT 0,
    event_emitted_at      TIMESTAMPTZ,
    alert_id              UUID,
    inserted_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (check_instance_id)
);

DROP TABLE IF EXISTS discovered_interfaces;
CREATE TABLE discovered_interfaces (
    timestamp       TIMESTAMPTZ NOT NULL,
    agent_id        TEXT,
    gateway_id       TEXT,
    device_ip       TEXT,
    device_id       TEXT,
    interface_uid   TEXT        NOT NULL,
    if_index        INT,
    if_name         TEXT,
    if_descr        TEXT,
    if_alias        TEXT,
    if_speed        BIGINT,
    speed_bps       BIGINT,
    mtu             INT,
    duplex          TEXT,
    if_type         INT,
    if_type_name    TEXT,
    interface_kind  TEXT,
    if_phys_address TEXT,
    ip_addresses    TEXT[],
    if_admin_status INT,
    if_oper_status  INT,
    metadata        JSONB,
    available_metrics JSONB,
    created_at      TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, device_id, interface_uid)
);

DROP TABLE IF EXISTS otel_traces;
CREATE TABLE otel_traces (
    timestamp            TIMESTAMPTZ NOT NULL,
    trace_id             TEXT,
    span_id              TEXT        NOT NULL,
    parent_span_id       TEXT,
    name                 TEXT,
    kind                 INT,
    start_time_unix_nano BIGINT,
    end_time_unix_nano   BIGINT,
    service_name         TEXT,
    service_version      TEXT,
    service_instance     TEXT,
    scope_name           TEXT,
    scope_version        TEXT,
    status_code          INT,
    status_message       TEXT,
    attributes           TEXT,
    resource_attributes  TEXT,
    events               TEXT,
    links                TEXT,
    created_at           TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, trace_id, span_id)
);

DROP TABLE IF EXISTS otel_metrics;
CREATE TABLE otel_metrics (
    timestamp        TIMESTAMPTZ NOT NULL,
    trace_id         TEXT,
    span_id          TEXT,
    service_name     TEXT,
    span_name        TEXT,
    span_kind        TEXT,
    duration_ms      FLOAT8,
    duration_seconds FLOAT8,
    metric_type      TEXT,
    http_method      TEXT,
    http_route       TEXT,
    http_status_code TEXT,
    grpc_service     TEXT,
    grpc_method      TEXT,
    grpc_status_code TEXT,
    is_slow          BOOLEAN,
    component        TEXT,
    level            TEXT,
    unit             TEXT,
    created_at       TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, span_name, service_name, span_id)
);

DROP TABLE IF EXISTS timeseries_metrics;
CREATE TABLE timeseries_metrics (
    timestamp        TIMESTAMPTZ NOT NULL,
    gateway_id        TEXT        NOT NULL,
    agent_id         TEXT,
    series_key       TEXT        NOT NULL,
    metric_name      TEXT        NOT NULL,
    metric_type      TEXT        NOT NULL,
    device_id        TEXT,
    value            FLOAT8      NOT NULL,
    unit             TEXT,
    tags             JSONB,
    partition        TEXT,
    scale            FLOAT8,
    is_delta         BOOLEAN,
    target_device_ip TEXT,
    if_index         INT,
    metadata         JSONB,
    created_at       TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, gateway_id, series_key)
);

DROP TABLE IF EXISTS cpu_metrics;
CREATE TABLE cpu_metrics (
    timestamp     TIMESTAMPTZ NOT NULL,
    gateway_id     TEXT        NOT NULL,
    agent_id      TEXT,
    host_id       TEXT,
    core_id       INT,
    usage_percent FLOAT8,
    frequency_hz  FLOAT8,
    label         TEXT,
    cluster       TEXT,
    device_id     TEXT,
    partition     TEXT,
    created_at    TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, gateway_id, core_id)
);

DROP TABLE IF EXISTS disk_metrics;
CREATE TABLE disk_metrics (
    timestamp       TIMESTAMPTZ NOT NULL,
    gateway_id       TEXT,
    agent_id        TEXT,
    host_id         TEXT,
    mount_point     TEXT,
    device_name     TEXT,
    total_bytes     BIGINT,
    used_bytes      BIGINT,
    available_bytes BIGINT,
    usage_percent   FLOAT8,
    device_id       TEXT,
    partition       TEXT,
    created_at      TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, gateway_id, mount_point)
);

DROP TABLE IF EXISTS memory_metrics;
CREATE TABLE memory_metrics (
    timestamp       TIMESTAMPTZ NOT NULL,
    gateway_id       TEXT,
    agent_id        TEXT,
    host_id         TEXT,
    total_bytes     BIGINT,
    used_bytes      BIGINT,
    available_bytes BIGINT,
    usage_percent   FLOAT8,
    device_id       TEXT,
    partition       TEXT,
    created_at      TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, gateway_id)
);

DROP TABLE IF EXISTS alerts;
CREATE TABLE alerts (
    id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    title                TEXT        NOT NULL,
    description          TEXT,
    severity             TEXT        NOT NULL DEFAULT 'warning',
    status               TEXT        NOT NULL DEFAULT 'pending',
    source_type          TEXT,
    source_id            TEXT,
    service_check_id     UUID,
    device_uid           TEXT,
    agent_uid            TEXT,
    event_id             UUID,
    event_time           TIMESTAMPTZ,
    metric_name          TEXT,
    metric_value         FLOAT8,
    threshold_value      FLOAT8,
    comparison           TEXT,
    triggered_at         TIMESTAMPTZ,
    acknowledged_at      TIMESTAMPTZ,
    acknowledged_by      TEXT,
    resolved_at          TIMESTAMPTZ,
    resolved_by          TEXT,
    resolution_note      TEXT,
    escalated_at         TIMESTAMPTZ,
    escalation_level     BIGINT      DEFAULT 0,
    escalation_reason    TEXT,
    notification_count   BIGINT      DEFAULT 0,
    last_notification_at TIMESTAMPTZ,
    suppressed_until     TIMESTAMPTZ,
    metadata             JSONB       DEFAULT '{}',
    tags                 TEXT[]      DEFAULT '{}',
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS virtualization_storage_systems;
DROP TABLE IF EXISTS virtualization_network_interfaces;
DROP TABLE IF EXISTS virtualization_host_disks;
DROP TABLE IF EXISTS virtualization_datastores;
DROP TABLE IF EXISTS virtualization_guests;
DROP TABLE IF EXISTS virtualization_hosts;
DROP TABLE IF EXISTS virtualization_clusters;

CREATE TABLE virtualization_clusters (
    id           UUID        PRIMARY KEY,
    provider     TEXT        NOT NULL,
    provider_ref TEXT        NOT NULL,
    name         TEXT        NOT NULL,
    status       TEXT,
    version      TEXT,
    metadata     JSONB       NOT NULL DEFAULT '{}',
    observed_at  TIMESTAMPTZ,
    inserted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE virtualization_hosts (
    id                 UUID        PRIMARY KEY,
    provider           TEXT        NOT NULL,
    provider_ref       TEXT        NOT NULL,
    cluster_id         UUID        REFERENCES virtualization_clusters(id),
    device_uid         TEXT        REFERENCES ocsf_devices(uid),
    name               TEXT        NOT NULL,
    status             TEXT,
    version            TEXT,
    cpu_ratio          FLOAT8,
    memory_used_bytes  BIGINT,
    memory_total_bytes BIGINT,
    uptime_seconds     BIGINT,
    metadata           JSONB       NOT NULL DEFAULT '{}',
    observed_at        TIMESTAMPTZ,
    inserted_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE virtualization_guests (
    id                 UUID        PRIMARY KEY,
    provider           TEXT        NOT NULL,
    provider_ref       TEXT        NOT NULL,
    host_id            UUID        REFERENCES virtualization_hosts(id),
    device_uid         TEXT        REFERENCES ocsf_devices(uid),
    name               TEXT,
    guest_type         TEXT        NOT NULL,
    vmid               BIGINT,
    status             TEXT,
    cpu_ratio          FLOAT8,
    memory_used_bytes  BIGINT,
    memory_total_bytes BIGINT,
    disk_used_bytes    BIGINT,
    disk_total_bytes   BIGINT,
    uptime_seconds     BIGINT,
    metadata           JSONB       NOT NULL DEFAULT '{}',
    observed_at        TIMESTAMPTZ,
    inserted_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE virtualization_datastores (
    id              UUID        PRIMARY KEY,
    provider        TEXT        NOT NULL,
    provider_ref    TEXT        NOT NULL,
    cluster_id      UUID        REFERENCES virtualization_clusters(id),
    host_id         UUID        REFERENCES virtualization_hosts(id),
    name            TEXT        NOT NULL,
    storage_type    TEXT,
    content         TEXT,
    active          BOOLEAN,
    enabled         BOOLEAN,
    shared          BOOLEAN,
    used_bytes      BIGINT,
    available_bytes BIGINT,
    total_bytes     BIGINT,
    metadata        JSONB       NOT NULL DEFAULT '{}',
    observed_at     TIMESTAMPTZ,
    inserted_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE virtualization_host_disks (
    id           UUID        PRIMARY KEY,
    provider     TEXT        NOT NULL,
    provider_ref TEXT        NOT NULL,
    host_id      UUID        NOT NULL REFERENCES virtualization_hosts(id),
    device_uid   TEXT        REFERENCES ocsf_devices(uid),
    path         TEXT,
    by_id        TEXT,
    disk_type    TEXT,
    vendor       TEXT,
    model        TEXT,
    health       TEXT,
    size_bytes   BIGINT,
    wearout      INT,
    usage        TEXT,
    metadata     JSONB       NOT NULL DEFAULT '{}',
    observed_at  TIMESTAMPTZ,
    inserted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE virtualization_network_interfaces (
    id             UUID        PRIMARY KEY,
    provider       TEXT        NOT NULL,
    provider_ref   TEXT        NOT NULL,
    host_id        UUID        NOT NULL REFERENCES virtualization_hosts(id),
    guest_id       UUID        REFERENCES virtualization_guests(id),
    guest_provider_ref TEXT,
    device_uid     TEXT        REFERENCES ocsf_devices(uid),
    name           TEXT        NOT NULL,
    interface_type TEXT,
    active         BOOLEAN,
    exists         BOOLEAN,
    method         TEXT,
    method6        TEXT,
    address        TEXT,
    cidr           TEXT,
    gateway        TEXT,
    bridge_ports   TEXT,
    vlan_id        INT,
    mac_address    TEXT,
    ip_addresses   TEXT[]      NOT NULL DEFAULT '{}',
    source         TEXT,
    metadata       JSONB       NOT NULL DEFAULT '{}',
    observed_at    TIMESTAMPTZ,
    inserted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE virtualization_storage_systems (
    id                  UUID        PRIMARY KEY,
    provider            TEXT        NOT NULL,
    provider_ref        TEXT        NOT NULL,
    cluster_id          UUID        REFERENCES virtualization_clusters(id),
    host_id             UUID        REFERENCES virtualization_hosts(id),
    name                TEXT        NOT NULL,
    storage_system_type TEXT        NOT NULL,
    health              TEXT,
    status              TEXT,
    metadata            JSONB       NOT NULL DEFAULT '{}',
    observed_at         TIMESTAMPTZ,
    inserted_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
