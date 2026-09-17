-- Reader columns the Network Flows UI needs after cutover.
-- protocol_group is CASE protocol_num IN (6,17); port series uses *_endpoint_port.
-- Fresh installs get these from 0001; ALTER covers lab tables created earlier.
-- StarRocks MySQL protocol does not accept ADD COLUMN IF NOT EXISTS.
-- Applied by the Bazel schema target, not Mix/Postgres migrations.
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN src_endpoint_port INT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN dst_endpoint_port INT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN protocol_num INT NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN protocol_name VARCHAR(32) NULL;
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN direction_label VARCHAR(32) NULL;
