-- Identity & reconciliation schema: network sightings, identifiers, fingerprints, subnet policies, and audit trails
BEGIN;

-- Ensure UUID generation is available for new tables
CREATE EXTENSION IF NOT EXISTS pgcrypto;

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

-- Device identifiers anchor reconciliation and merges
CREATE TABLE IF NOT EXISTS device_identifiers (
    device_id        TEXT            NOT NULL REFERENCES unified_devices(device_id),
    id_type          TEXT            NOT NULL,
    id_value         TEXT            NOT NULL,
    confidence       TEXT            NOT NULL,
    source           TEXT,
    first_seen       TIMESTAMPTZ     NOT NULL DEFAULT now(),
    last_seen        TIMESTAMPTZ     NOT NULL DEFAULT now(),
    verified         BOOLEAN         NOT NULL DEFAULT FALSE,
    metadata         JSONB           NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (id_type, id_value)
);
CREATE INDEX IF NOT EXISTS idx_device_identifiers_device_type ON device_identifiers (device_id, id_type);
CREATE INDEX IF NOT EXISTS idx_device_identifiers_strong ON device_identifiers (id_type, id_value) WHERE confidence = 'strong';

-- Audit trail for sighting lifecycle events
CREATE TABLE IF NOT EXISTS sighting_events (
    event_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    sighting_id      UUID            NOT NULL REFERENCES network_sightings(sighting_id) ON DELETE CASCADE,
    device_id        TEXT            REFERENCES unified_devices(device_id),
    event_type       TEXT            NOT NULL,
    actor            TEXT            NOT NULL DEFAULT 'system',
    details          JSONB           NOT NULL DEFAULT '{}'::jsonb,
    created_at       TIMESTAMPTZ     NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sighting_events_sighting ON sighting_events (sighting_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sighting_events_device ON sighting_events (device_id, created_at DESC);

-- Merge audit for device reconciliations
CREATE TABLE IF NOT EXISTS merge_audit (
    event_id         UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    from_device_id   TEXT            NOT NULL REFERENCES unified_devices(device_id),
    to_device_id     TEXT            NOT NULL REFERENCES unified_devices(device_id),
    reason           TEXT,
    confidence_score NUMERIC,
    source           TEXT,
    details          JSONB           NOT NULL DEFAULT '{}'::jsonb,
    created_at       TIMESTAMPTZ     NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_merge_audit_to_device ON merge_audit (to_device_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_merge_audit_from_device ON merge_audit (from_device_id, created_at DESC);

COMMIT;
