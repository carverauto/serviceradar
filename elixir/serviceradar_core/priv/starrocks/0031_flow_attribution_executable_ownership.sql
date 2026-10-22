-- The package that owns each observed process's executable (#5752,
-- add-srql-exposure-intelligence design Decision 18): netprobe's
-- ExecutableOwnership reference as JSON, with the package identity key core
-- derives for a RESOLVED reference. NULL for observations from older agents.
-- Fresh installs get this from 0026's CREATE; this ALTER covers existing
-- warehouses. JSON Stream Load ignores unknown keys, so the writer may ship
-- before this applies.
ALTER TABLE serviceradar.flow_process_attribution_observations ADD COLUMN executable_ownership VARCHAR(65533);
