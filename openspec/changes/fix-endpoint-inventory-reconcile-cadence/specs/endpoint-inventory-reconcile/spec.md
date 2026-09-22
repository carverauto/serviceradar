## ADDED Requirements

### Requirement: Collection Cadence Is Independent Of Reconcile Upload
The endpoint inventory producer SHALL skip a full collection walk when configured cadence has not elapsed and source mtimes are unchanged, even if the server has requested a reconcile-floor upload.

#### Scenario: Hourly timer inside 24h cadence skips the walk
- **GIVEN** a successful cached collection from less than the configured cadence ago
- **AND** package-source mtimes are unchanged
- **AND** no reconcile-floor upload is outstanding
- **WHEN** the producer timer wakes
- **THEN** it SHALL NOT walk or re-parse package sources
- **AND** it SHALL emit an unchanged scan using the cached package-set and artifact hashes

#### Scenario: Reconcile floor reuses the cached package set
- **GIVEN** a successful cached collection from less than the configured cadence ago
- **AND** package-source mtimes are unchanged
- **AND** a reconcile-floor upload is outstanding
- **WHEN** the producer timer wakes
- **THEN** it SHALL NOT walk or re-parse package sources
- **AND** it SHALL emit a changed full-upload payload with the cached package-set hash, artifact hash, and SBOM

#### Scenario: Source change still collects
- **GIVEN** a reconcile-floor upload is outstanding
- **AND** a package-source mtime has changed since the last full collection
- **WHEN** the producer timer wakes
- **THEN** it SHALL perform a real collection

### Requirement: Reconcile Floor Directive Is One-Shot
The control plane SHALL send `endpoint_inventory.reconcile_floor` only when an ingest observation newly crosses the unchanged-scan or max-age floor.

#### Scenario: First observation that crosses the floor sends the directive
- **GIVEN** the current scan is below the unchanged-scan floor
- **WHEN** an unchanged ingest observation reaches the floor
- **THEN** the ingest result SHALL include a reconcile-floor directive
- **AND** the current scan row SHALL record `reconcile_floor_due` true

#### Scenario: Later duplicate ingest does not resend the directive
- **GIVEN** the current scan already has `reconcile_floor_due` true
- **WHEN** the same or another unchanged payload is ingested as a duplicate or hash-noop
- **THEN** the ingest result SHALL NOT include a reconcile-floor directive

### Requirement: Upload Ack Clears Reconcile Before New Floor Stamps
The agent SHALL apply endpoint-inventory upload acknowledgements before recording a new server reconcile-floor request from the same gateway response.

#### Scenario: Full-upload ack ignores a leftover floor directive
- **GIVEN** the gateway response acknowledges a full changed endpoint-inventory upload
- **AND** the same response includes a reconcile-floor directive
- **WHEN** the agent records the response
- **THEN** the local cache SHALL treat the upload as acknowledged
- **AND** it SHALL NOT store a new `ServerReconcileRequestedAt` from that leftover directive
