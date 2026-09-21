-- The event documents SRQL reads by path, and the log level it filters on.
-- CNPG answers event_type / finding_uid / device_id / hostname filters and the
-- anomaly-findings rollup from the metadata, unmapped and device JSON, and no
-- flattened column can stand in for them: each filter reads several paths, and
-- the device filter scans the whole document -- observables included -- for a
-- raw id. They are kept as JSON text and read with get_json_string, like
-- timeseries_metrics.tags.
-- Fresh installs get these from 0004; ALTER covers tables created earlier.
-- A row written before this file has NULL documents, which every path reads
-- as "key absent".
--
-- events_hourly (0017) is a day-partitioned async materialized view over this
-- table, and nothing here re-activates it because nothing needs to. Measured
-- on StarRocks 3.5.21, shared-data: after ALTER TABLE ... ADD COLUMN on a
-- partitioned primary-key base table reached FINISHED, the dependent
-- day-partitioned async view stayed IS_ACTIVE = true with no INACTIVE_REASON,
-- and its next refresh succeeded. A single-node 3.5.21 given this file's five
-- ALTERs one after another behaved the same way.
-- The same run showed the one real constraint: a second ALTER on a table is
-- refused while the first is still running, and a new column is not visible to
-- INSERT until its ALTER is FINISHED. SchemaMigrator awaits each ADD COLUMN
-- before it sends the next statement, which is what makes this file safe as
-- written.
ALTER TABLE serviceradar.events ADD COLUMN log_level VARCHAR(32) NULL;
ALTER TABLE serviceradar.events ADD COLUMN metadata VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN unmapped VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN device VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events ADD COLUMN observables VARCHAR(1048576) NULL;
