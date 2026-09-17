-- Attribution partial-update columns for historical flow enrichment.
-- Fresh installs get these from 0001; ALTER covers lab tables created earlier.
-- Apply via the StarRocks SQL console (FE:9030). Not Ecto.
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN pid INT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN comm VARCHAR(256) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN cmdline VARCHAR(65533) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN workload_identity VARCHAR(65533) NULL;
