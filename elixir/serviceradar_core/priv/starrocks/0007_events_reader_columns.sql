-- Flattened event-reader columns for remaining CNPG-direct consumers.
-- Fresh installs get these from 0004; ALTER covers lab tables created earlier.
-- Apply via the StarRocks SQL console (FE:9030). Not Ecto.
ALTER TABLE serviceradar.events ADD COLUMN src_endpoint_ip VARCHAR(64) NULL;
ALTER TABLE serviceradar.events ADD COLUMN firewall_rule_name VARCHAR(256) NULL;
ALTER TABLE serviceradar.events ADD COLUMN source_type VARCHAR(64) NULL;
