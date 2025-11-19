-- Deterministic CNPG schema subset for SRQL API tests.
-- The harness drops tables before creation so each test starts cleanly.

DROP TABLE IF EXISTS unified_devices;

CREATE TABLE unified_devices (
    device_id         TEXT        PRIMARY KEY,
    ip                TEXT,
    poller_id         TEXT,
    agent_id          TEXT,
    hostname          TEXT,
    mac               TEXT,
    discovery_sources TEXT[],
    is_available      BOOLEAN     NOT NULL DEFAULT FALSE,
    first_seen        TIMESTAMPTZ NOT NULL,
    last_seen         TIMESTAMPTZ NOT NULL,
    metadata          JSONB       NOT NULL DEFAULT '{}'::jsonb,
    device_type       TEXT,
    service_type      TEXT,
    service_status    TEXT,
    last_heartbeat    TIMESTAMPTZ,
    os_info           TEXT,
    version_info      TEXT
);
