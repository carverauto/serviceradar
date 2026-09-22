-- Sampler address is required for exporter-cache discovery after flow cutover.
-- Additive nullable column on the existing PRIMARY KEY table.
-- StarRocks MySQL console does not accept ADD COLUMN IF NOT EXISTS.
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN sampler_address VARCHAR(64);
