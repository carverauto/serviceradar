-- Observation-snapshot attribution columns (pid/comm) for attributed_flows.
-- Postgres reads these from ocsf_payload; StarRocks stores them as columns.
-- 0008 used ADD COLUMN IF NOT EXISTS, which the MySQL protocol rejects.
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN pid INT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN comm VARCHAR(256) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN cmdline VARCHAR(65533) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN workload_identity VARCHAR(65533) NULL;
