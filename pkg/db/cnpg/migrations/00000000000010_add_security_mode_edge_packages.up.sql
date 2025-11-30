-- Add explicit security_mode to edge onboarding packages (defaults to SPIRE for legacy rows)
ALTER TABLE edge_onboarding_packages
    ADD COLUMN IF NOT EXISTS security_mode TEXT DEFAULT 'spire';
