-- Ingest-time application classification for flows (issue #4851).
-- Same label CNPG computes at query time (FLOW_APP_EXPR: protocol/port
-- baseline, overridden by enabled netflow_app_classification_rules rows by
-- priority DESC, specificity DESC, id ASC). Pre-migration rows are NULL and
-- read as 'unknown'; rule changes affect flows written after them.
-- Fresh installs get this from 0001 after the next CREATE; ALTER covers
-- existing deployments. JSON Stream Load ignores unknown keys, so the writer
-- may ship before this applies.
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN app VARCHAR(64) NULL;
