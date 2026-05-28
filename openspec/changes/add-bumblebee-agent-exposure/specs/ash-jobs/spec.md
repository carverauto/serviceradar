## ADDED Requirements
### Requirement: Bumblebee Exposure Catalog Refresh Job
The system SHALL run a core-owned AshOban-backed catalog refresh job that fetches configured Bumblebee exposure catalog sources, validates their schema, normalizes entries, materializes immutable catalog artifacts, and promotes a new active catalog snapshot only after successful validation.

#### Scenario: Catalog refresh succeeds
- **GIVEN** the configured Bumblebee catalog source is reachable and valid
- **WHEN** the refresh job runs
- **THEN** a new platform-scoped catalog snapshot is stored
- **AND** the normalized catalog artifact is written to datasvc-backed NATS Object Storage under an immutable object key
- **AND** the snapshot becomes the active catalog used for Bumblebee scan configuration
- **AND** the job records source revision, catalog version, content SHA256, object key, entry counts, promotion time, and validation outcome
- **AND** AshPaperTrail records the catalog snapshot promotion with system actor and job metadata
- **AND** the job records a success lifecycle event in `platform.ocsf_events` with source, snapshot, artifact, entry count, and catalog version metadata

#### Scenario: Catalog refresh fails
- **GIVEN** the configured Bumblebee catalog source is unreachable, malformed, or uses an unsupported schema version
- **WHEN** the refresh job runs
- **THEN** the active catalog snapshot remains unchanged
- **AND** the job records bounded failure telemetry without disabling existing agent scans
- **AND** the job records a failure lifecycle event in `platform.ocsf_events` with source identity and a bounded failure reason

#### Scenario: Catalog entries are normalized
- **GIVEN** one or more catalog files share a supported schema version
- **WHEN** the refresh job parses the catalog
- **THEN** each entry is normalized by catalog ID, ecosystem, package name, affected versions, severity, source URL metadata, and snapshot ID
- **AND** duplicate entries resolve deterministically

### Requirement: Bumblebee Catalog Auditability
The system SHALL use AshPaperTrail for operator-managed Bumblebee catalog source configuration and catalog snapshot promotion state. High-volume catalog entry rows and scan findings SHALL use dedicated storage/history rather than per-ingest AshPaperTrail versions.

#### Scenario: Operator changes catalog source
- **GIVEN** an authorized operator updates the Bumblebee catalog source URL, pinned revision, or refresh schedule
- **WHEN** the change is saved
- **THEN** AshPaperTrail SHALL record the prior value, new value, actor, action name, and action inputs

#### Scenario: Scan finding ingest is not versioned per row
- **GIVEN** a Bumblebee scan reports many findings
- **WHEN** the findings are ingested
- **THEN** the system SHALL persist current finding state and bounded history through the finding storage model
- **AND** it SHALL NOT create an AshPaperTrail version for every finding row update

### Requirement: Bumblebee Catalog Artifact Versioning
The system SHALL treat every promoted Bumblebee catalog as an immutable versioned artifact. Mutable aliases such as "latest" MAY point to an active snapshot, but agents and findings SHALL reference the immutable snapshot identity and content hash.

#### Scenario: Catalog artifact is promoted
- **GIVEN** a validated candidate catalog snapshot exists
- **WHEN** the snapshot is promoted
- **THEN** the system SHALL assign or preserve an immutable snapshot reference
- **AND** store the normalized artifact object key, byte size, content SHA256, upstream source revision, normalized catalog version, and promoted timestamp
- **AND** expose that snapshot reference for agent configuration and scan result correlation

#### Scenario: New catalog supersedes previous catalog
- **GIVEN** an active catalog snapshot is already assigned to agents
- **WHEN** a newer validated snapshot is promoted
- **THEN** the prior snapshot remains addressable for historical findings
- **AND** new assignments reference the newer immutable snapshot
- **AND** old findings continue to identify the exact snapshot that produced them
