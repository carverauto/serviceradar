-- Flattened event-reader columns for remaining CNPG-direct consumers.
-- Fresh installs get these from 0004; ALTER covers lab tables created earlier.
-- Applied by the Bazel schema target, not Mix/Postgres migrations.
ALTER TABLE serviceradar.events ADD COLUMN IF NOT EXISTS src_endpoint_ip VARCHAR(64) NULL;
ALTER TABLE serviceradar.events ADD COLUMN IF NOT EXISTS firewall_rule_name VARCHAR(256) NULL;
ALTER TABLE serviceradar.events ADD COLUMN IF NOT EXISTS source_type VARCHAR(64) NULL;
