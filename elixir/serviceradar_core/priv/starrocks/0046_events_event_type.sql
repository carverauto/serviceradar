-- Materialize event_type on serviceradar.events so SRQL event_type filters
-- query a bloom-filtered VARCHAR(128) column instead of parsing metadata and
-- unmapped JSON with 6x get_json_string() per row.
-- Fresh installs get the column and bloom filter from 0004; ALTER covers tables
-- created earlier. Rows written before this file have NULL in event_type.
-- SchemaMigrator awaits ADD COLUMN before applying bloom_filter_columns and
-- skips either statement when the table already matches.
ALTER TABLE serviceradar.events ADD COLUMN event_type VARCHAR(128) NULL;
ALTER TABLE serviceradar.events SET ("bloom_filter_columns" = "event_type");
