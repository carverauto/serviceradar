-- =================================================================
-- == Edge Onboarding Schema
-- =================================================================
-- Provides persistent storage for edge poller onboarding packages
-- and their audit trail. Packages are stored in a ReplacingMergeTree
-- so updates can be written as full-row inserts keyed by package_id.
-- Events are captured in an append-only MergeTree for auditing.

CREATE TABLE IF NOT EXISTS edge_onboarding_packages (
    package_id UUID,
    label String,
    poller_id String,
    site String,
    status LowCardinality(String),
    downstream_spiffe_id String,
    selectors Array(String),
    join_token_ciphertext String,
    join_token_expires_at DateTime64(3),
    bundle_ciphertext String,
    download_token_hash String,
    download_token_expires_at DateTime64(3),
    created_by String,
    created_at DateTime64(3),
    updated_at DateTime64(3),
    delivered_at Nullable(DateTime64(3)),
    activated_at Nullable(DateTime64(3)),
    activated_from_ip Nullable(String),
    last_seen_spiffe_id Nullable(String),
    revoked_at Nullable(DateTime64(3)),
    metadata_json String,
    notes String
) ENGINE = ReplacingMergeTree(updated_at)
PARTITION BY toYYYYMM(created_at)
ORDER BY (package_id);

CREATE TABLE IF NOT EXISTS edge_onboarding_events (
    event_time DateTime64(3),
    package_id UUID,
    event_type LowCardinality(String),
    actor String,
    source_ip String,
    details_json String
) ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, package_id);

