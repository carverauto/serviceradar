-- Sampler address is required for exporter-cache discovery after flow cutover.
-- Additive nullable column on the existing PRIMARY KEY table.
ALTER TABLE serviceradar.ocsf_network_activity
ADD COLUMN IF NOT EXISTS sampler_address VARCHAR(64);
