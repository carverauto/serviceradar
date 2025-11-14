-- =================================================================
-- == Edge Onboarding Schema
-- =================================================================
-- Provides persistent storage for edge poller onboarding packages
-- and their audit trail. Packages are stored in a ReplacingMergeTree
-- so updates can be written as full-row inserts keyed by package_id.
-- Events are captured in an append-only MergeTree for auditing.

CREATE STREAM IF NOT EXISTS edge_onboarding_packages (
    package_id uuid,
    label string,
    poller_id string,
    site string,
    status string,
    downstream_spiffe_id string,
    selectors array(string),
    join_token_ciphertext string,
    join_token_expires_at DateTime64(3),
    bundle_ciphertext string,
    download_token_hash string,
    download_token_expires_at DateTime64(3),
    created_by string,
    created_at DateTime64(3),
    updated_at DateTime64(3),
    delivered_at nullable(DateTime64(3)),
    activated_at nullable(DateTime64(3)),
    activated_from_ip nullable(string),
    last_seen_spiffe_id nullable(string),
    revoked_at nullable(DateTime64(3)),
    metadata_json string,
    notes string
) ENGINE = Stream(1, rand())
PARTITION BY to_YYYYMM(created_at)
PRIMARY KEY (package_id)
ORDER BY (package_id)
SETTINGS mode='changelog_kv', version_column='updated_at';

CREATE STREAM IF NOT EXISTS edge_onboarding_events (
    event_time DateTime64(3),
    package_id uuid,
    event_type string,
    actor string,
    source_ip string,
    details_json string
) ENGINE = Stream(1, rand())
PARTITION BY to_YYYYMM(event_time)
PRIMARY KEY (event_time, package_id)
ORDER BY (event_time, package_id);
