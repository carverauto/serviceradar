-- Deterministic CNPG schema subset for SRQL API tests.
-- The harness drops tables before creation so each test starts cleanly.

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
    poller_id           TEXT,
    agent_id            TEXT,
    discovery_sources   TEXT[],
    is_available        BOOLEAN,
    metadata            JSONB
);

DROP TABLE IF EXISTS pollers;
CREATE TABLE pollers (
    poller_id           TEXT        PRIMARY KEY,
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
    updated_at          TIMESTAMPTZ
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

DROP TABLE IF EXISTS logs;
CREATE TABLE logs (
    timestamp           TIMESTAMPTZ NOT NULL,
    trace_id            TEXT,
    span_id             TEXT,
    severity_text       TEXT,
    severity_number     INT,
    body                TEXT,
    service_name        TEXT,
    service_version     TEXT,
    service_instance    TEXT,
    scope_name          TEXT,
    scope_version       TEXT,
    attributes          TEXT,
    resource_attributes TEXT,
    created_at          TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, trace_id, span_id)
);

DROP TABLE IF EXISTS service_status;
CREATE TABLE service_status (
    timestamp    TIMESTAMPTZ NOT NULL,
    poller_id    TEXT        NOT NULL,
    agent_id     TEXT,
    service_name TEXT        NOT NULL,
    service_type TEXT,
    available    BOOLEAN     NOT NULL,
    message      TEXT,
    details      TEXT,
    partition    TEXT,
    created_at   TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, poller_id, service_name)
);

DROP TABLE IF EXISTS discovered_interfaces;
CREATE TABLE discovered_interfaces (
    timestamp       TIMESTAMPTZ NOT NULL,
    agent_id        TEXT,
    poller_id       TEXT,
    device_ip       TEXT,
    device_id       TEXT,
    if_index        INT,
    if_name         TEXT,
    if_descr        TEXT,
    if_alias        TEXT,
    if_speed        BIGINT,
    if_phys_address TEXT,
    ip_addresses    TEXT[],
    if_admin_status INT,
    if_oper_status  INT,
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, device_id, if_index)
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
    created_at       TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, span_name, service_name, span_id)
);

DROP TABLE IF EXISTS timeseries_metrics;
CREATE TABLE timeseries_metrics (
    timestamp        TIMESTAMPTZ NOT NULL,
    poller_id        TEXT        NOT NULL,
    agent_id         TEXT,
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
    PRIMARY KEY (timestamp, poller_id, metric_name)
);

DROP TABLE IF EXISTS cpu_metrics;
CREATE TABLE cpu_metrics (
    timestamp     TIMESTAMPTZ NOT NULL,
    poller_id     TEXT        NOT NULL,
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
    PRIMARY KEY (timestamp, poller_id, core_id)
);

DROP TABLE IF EXISTS disk_metrics;
CREATE TABLE disk_metrics (
    timestamp       TIMESTAMPTZ NOT NULL,
    poller_id       TEXT,
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
    PRIMARY KEY (timestamp, poller_id, mount_point)
);

DROP TABLE IF EXISTS memory_metrics;
CREATE TABLE memory_metrics (
    timestamp       TIMESTAMPTZ NOT NULL,
    poller_id       TEXT,
    agent_id        TEXT,
    host_id         TEXT,
    total_bytes     BIGINT,
    used_bytes      BIGINT,
    available_bytes BIGINT,
    usage_percent   FLOAT8,
    device_id       TEXT,
    partition       TEXT,
    created_at      TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (timestamp, poller_id)
);
