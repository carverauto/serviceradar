-- Inline tombstone metadata on edge onboarding packages and retire the standalone stream.

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS deleted_by string DEFAULT '';

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS deleted_reason string DEFAULT '';

DROP STREAM IF EXISTS edge_onboarding_package_tombstones SYNC;
