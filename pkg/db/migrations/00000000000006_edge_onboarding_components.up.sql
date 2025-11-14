-- Expand edge onboarding packages to support multi-component onboarding.
-- Adds component classification, parent linkage, checker metadata, and KV revision tracking.
ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS component_id string DEFAULT '';

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS component_type string DEFAULT 'poller';

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS parent_type string DEFAULT '';

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS parent_id string DEFAULT '';

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS checker_kind string DEFAULT '';

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS checker_config_json string DEFAULT '{}';

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS kv_revision uint64 DEFAULT 0;
