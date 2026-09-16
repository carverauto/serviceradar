-- Attribution partial-update columns for historical flow enrichment.
-- Fresh installs get these from 0001; ALTER covers lab tables created earlier.
-- Applied by the Bazel schema target, not Mix/Postgres migrations.
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN IF NOT EXISTS pid INT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN IF NOT EXISTS comm VARCHAR(256) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN IF NOT EXISTS cmdline VARCHAR(65533) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN IF NOT EXISTS workload_identity VARCHAR(65533) NULL;
