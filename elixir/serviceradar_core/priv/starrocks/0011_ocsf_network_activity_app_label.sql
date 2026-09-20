-- Application label used by Network Flows "Activity by Application".
-- Fresh installs get this from 0001 after the next CREATE; ALTER covers lab.
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN dst_service_label VARCHAR(128) NULL;
