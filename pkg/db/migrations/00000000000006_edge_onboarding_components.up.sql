-- Expand edge onboarding packages to support multi-component onboarding.
-- Adds component classification, parent linkage, checker metadata, and KV revision tracking.
ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS component_id string DEFAULT '' AFTER label;

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS component_type string DEFAULT 'poller' AFTER component_id;

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS parent_type string DEFAULT '' AFTER component_type;

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS parent_id string DEFAULT '' AFTER parent_type;

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS checker_kind string DEFAULT '' AFTER parent_id;

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS checker_config_json string DEFAULT '{}' AFTER checker_kind;

ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS kv_revision uint64 DEFAULT 0 AFTER metadata_json;
