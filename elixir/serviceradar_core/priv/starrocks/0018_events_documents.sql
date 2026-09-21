-- The event documents SRQL reads by path, and the log level it filters on.
-- CNPG answers event_type / finding_uid / device_id / hostname filters and the
-- anomaly-findings rollup from the metadata, unmapped and device JSON, and no
-- flattened column can stand in for them: each filter reads several paths, and
-- the device filter scans the whole document for a raw id. They are kept as
-- JSON text and read with get_json_string, like timeseries_metrics.tags.
-- Fresh installs get these from 0004; ALTER covers tables created earlier.
-- A row written before this file has NULL documents, which every path reads
-- as "key absent".
ALTER TABLE serviceradar.events ADD COLUMN log_level VARCHAR(32) NULL;
ALTER TABLE serviceradar.events ADD COLUMN metadata VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN unmapped VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN device VARCHAR(1048576) NULL;
