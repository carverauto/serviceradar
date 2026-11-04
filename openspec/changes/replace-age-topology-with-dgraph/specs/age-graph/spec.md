## REMOVED Requirements

### Requirement: AGE Query Execution
**Reason**: Apache AGE is retired; no component issues Cypher. Topology writes and reads go through typed Dgraph operations.
**Migration**: See `dgraph-topology` ("Dgraph is the only topology backend").

### Requirement: AGE Result Type Handling
**Reason**: Nothing queries AGE, so no `agtype` result is decoded.
**Migration**: None; Dgraph returns JSON through the typed NIF.

### Requirement: AGE-authoritative topology read model
**Reason**: Dgraph canonical topology is the only authoritative read model.
**Migration**: See `dgraph-topology` ("Dgraph-authoritative topology read model").

### Requirement: MTR Path Graph Projection
**Reason**: MTR paths are projected into Dgraph only.
**Migration**: See `mtr-diagnostics` ("Apache AGE Path Projection", now Dgraph-only).
