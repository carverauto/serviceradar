-- CNPG scalar columns the UI/SRQL still need on StarRocks.
-- JSON blobs (ocsf_payload, metadata) stay flattened; exporter names/GeoIP
-- remain catalog or ingest-enrichment, not copies of CNPG hypertables.
-- MySQL protocol does not accept ADD COLUMN IF NOT EXISTS.

ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN bytes_total BIGINT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN packets_total BIGINT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN start_time DATETIME NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN end_time DATETIME NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN src_as_number INT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN dst_as_number INT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN tcp_flags INT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN `partition` VARCHAR(128) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN input_snmp INT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN output_snmp INT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN src_mac VARCHAR(64) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN dst_mac VARCHAR(64) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN src_mac_vendor VARCHAR(128) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN dst_mac_vendor VARCHAR(128) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN src_hosting_provider VARCHAR(128) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN dst_hosting_provider VARCHAR(128) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN protocol_source VARCHAR(64) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN direction_source VARCHAR(64) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN dst_service_source VARCHAR(64) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN src_prefix_tags VARCHAR(65533) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN dst_prefix_tags VARCHAR(65533) NULL;

ALTER TABLE serviceradar.timeseries_metrics ADD COLUMN target_device_ip VARCHAR(64) NULL;
ALTER TABLE serviceradar.timeseries_metrics ADD COLUMN tags VARCHAR(65533) NULL;

ALTER TABLE serviceradar.logs ADD COLUMN trace_id VARCHAR(64) NULL;
ALTER TABLE serviceradar.logs ADD COLUMN span_id VARCHAR(64) NULL;
ALTER TABLE serviceradar.logs ADD COLUMN event_name VARCHAR(256) NULL;
ALTER TABLE serviceradar.logs ADD COLUMN source_ip VARCHAR(64) NULL;
ALTER TABLE serviceradar.logs ADD COLUMN service_version VARCHAR(64) NULL;
ALTER TABLE serviceradar.logs ADD COLUMN observed_timestamp DATETIME NULL;

ALTER TABLE serviceradar.events ADD COLUMN message VARCHAR(65533) NULL;
ALTER TABLE serviceradar.events ADD COLUMN activity_name VARCHAR(128) NULL;
ALTER TABLE serviceradar.events ADD COLUMN status VARCHAR(64) NULL;
ALTER TABLE serviceradar.events ADD COLUMN status_id INT NULL;
ALTER TABLE serviceradar.events ADD COLUMN log_name VARCHAR(256) NULL;
ALTER TABLE serviceradar.events ADD COLUMN log_provider VARCHAR(128) NULL;
ALTER TABLE serviceradar.events ADD COLUMN trace_id VARCHAR(64) NULL;
ALTER TABLE serviceradar.events ADD COLUMN span_id VARCHAR(64) NULL;
