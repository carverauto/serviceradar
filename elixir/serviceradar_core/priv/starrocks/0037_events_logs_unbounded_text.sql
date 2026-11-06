-- Free text in events and logs is stored whole. CNPG keeps these columns as
-- unbounded text; the warehouse widths were guesses, and a value past one was
-- cut (events) or made StarRocks filter the whole row out of its load (logs).
-- With a dataset cut over the warehouse is its only store, so either is lost
-- data. Every value arrives inside one NATS message, which the shipped broker
-- caps at 1 MiB, so VARCHAR(1048576) holds whatever can arrive (as in 0036).
-- Identifier columns (trace_id, span_id, src_endpoint_ip, source_ip) keep
-- their width: a value past it is not a valid identifier, and EventWriter
-- stores NULL and counts it rather than a cut one.
-- Fresh installs get these widths from 0003 and 0004. None of these columns is
-- a key or sort column, and no materialized view reads them: events_hourly
-- (0017, 0027) reads only `time` and severity_id, and logs has no rollup.
-- Increasing a VARCHAR length is a supported schema change for a value column.
-- SchemaMigrator skips a MODIFY whose column already has this type, and awaits
-- each one before the next, as it does for ADD COLUMN: StarRocks refuses a
-- second ALTER on a table while one is running.
ALTER TABLE serviceradar.events MODIFY COLUMN severity VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events MODIFY COLUMN source VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events MODIFY COLUMN firewall_rule_name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events MODIFY COLUMN source_type VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events MODIFY COLUMN message VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events MODIFY COLUMN activity_name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events MODIFY COLUMN status VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events MODIFY COLUMN log_name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events MODIFY COLUMN log_provider VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.events MODIFY COLUMN log_level VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.logs MODIFY COLUMN ingest_identity VARCHAR(1048576) NOT NULL;
ALTER TABLE serviceradar.logs MODIFY COLUMN severity_text VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.logs MODIFY COLUMN body VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.logs MODIFY COLUMN service_name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.logs MODIFY COLUMN source VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.logs MODIFY COLUMN ingest_agent_id VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.logs MODIFY COLUMN ingest_partition VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.logs MODIFY COLUMN event_name VARCHAR(1048576) NULL;
ALTER TABLE serviceradar.logs MODIFY COLUMN service_version VARCHAR(1048576) NULL;
