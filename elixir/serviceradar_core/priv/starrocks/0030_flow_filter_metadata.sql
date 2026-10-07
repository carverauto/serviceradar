-- Preserve the source and attribution metadata exposed by flow filters.
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN flow_source VARCHAR(64);
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN uid BIGINT;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN container_id VARCHAR(256);
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN public_endpoint VARCHAR(65533);
