-- Introduce tombstone tracking for edge onboarding packages and apply a retention policy.

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS deleted_at nullable(DateTime64(3));

ALTER STREAM edge_onboarding_packages
    MODIFY TTL to_datetime(updated_at) + INTERVAL 365 DAY;
