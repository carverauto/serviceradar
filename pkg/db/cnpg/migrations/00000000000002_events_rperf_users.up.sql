-- CloudEvents + rperf metrics + user management tables for CNPG/Timescale

-- CloudEvents table mirrors the legacy `events` stream but stores rows in a hypertable.
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
SELECT add_retention_policy('events', INTERVAL '3 days', if_not_exists => TRUE);
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_id_unique ON events (id, event_timestamp);
CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events (event_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_events_subject ON events (subject);

-- RPerf metrics hypertable (3-day retention to match prior defaults).
CREATE TABLE IF NOT EXISTS rperf_metrics (
    timestamp      TIMESTAMPTZ   NOT NULL,
    poller_id      TEXT          NOT NULL,
    service_name   TEXT          NOT NULL,
    message        TEXT,
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);
SELECT create_hypertable('rperf_metrics','timestamp', if_not_exists => TRUE);
SELECT add_retention_policy('rperf_metrics', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_rperf_metrics_poller_time ON rperf_metrics (poller_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_rperf_metrics_service ON rperf_metrics (service_name);

-- User management table used by auth flows (no TTL).
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
