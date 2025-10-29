-- Ensure edge onboarding packages include the downstream entry identifier for revocation flows.
ALTER STREAM edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS downstream_entry_id string DEFAULT '';
