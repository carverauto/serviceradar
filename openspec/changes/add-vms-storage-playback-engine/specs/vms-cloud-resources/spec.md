## ADDED Requirements

### Requirement: Isolated hosted media provisioning
The SaaS control plane SHALL provision or explicitly adopt purpose-scoped private media resources through resumable steps, while each ServiceRadar runtime remains a dedicated deployment.

#### Scenario: Provider success followed by provisioning restart
- **WHEN** a bucket exists but a subsequent step fails
- **THEN** retry SHALL reconcile persisted identity and ownership before reuse
- **AND** SHALL not duplicate resources, adopt unrelated buckets or enable recording before security probes pass

### Requirement: Least-privilege media credential custody
The system SHALL keep infrastructure secret material in approved custody and runtime Secret references, separate recorder/reader/deletion access and verify private access boundaries.

#### Scenario: Policy drift or unauthorized access
- **WHEN** a bucket becomes publicly accessible or another environment attempts access
- **THEN** readiness SHALL fail and unsafe new admission SHALL stop
- **AND** remediation SHALL preserve provider-managed limited-key constraints

#### Scenario: Rotation during active uploads
- **WHEN** media credentials rotate
- **THEN** a probed replacement generation SHALL become active before retiring the old generation
- **AND** multipart recovery SHALL remain possible without exposing keys in chart values, APIs or logs

### Requirement: Versioned capability and budget contract
The control plane and runtime SHALL negotiate applied configuration/capability revisions and enforce explicit recording, storage, egress and worker budgets before hosted admission.

#### Scenario: Unsupported capability or exhausted quota
- **WHEN** the configured endpoint, runtime or worker pool cannot meet a requested capability or budget
- **THEN** that capability SHALL remain unavailable with an actionable state
- **AND** existing unrelated recording/live consumers SHALL remain isolated

#### Scenario: Qualification report is parsed
- **WHEN** a version 1 archive qualification report is supplied
- **THEN** the product SHALL reject unsupported versions, unknown or missing fields and out-of-bounds values, and compute canonical content identity for accepted reports
- **AND** SHALL preserve explicit encryption attestation and each encryption-policy denial as separate observations
- **AND** parsing SHALL NOT authenticate the reporter, establish freshness, install credentials or grant readiness or dispatch authority

#### Scenario: Private qualification receipt is retained
- **WHEN** an authenticated control-plane caller submits a versioned report or withdrawal for a retained archive binding
- **THEN** the runtime SHALL bound and validate the wire document, reject duplicate JSON keys, and match the report to the retained destination
- **AND** SHALL persist increasing revisions, return the original receipt for an identical current retry, and reject stale or conflicting revisions
- **AND** a withdrawal SHALL retain its revision high-water mark without claiming provider credential revocation
- **AND** receipt status SHALL remain unapplied and unavailable, including when every observation passes
- **AND** the caller credential SHALL NOT be treated as independently authenticated environment identity or as storage authority

### Requirement: Preservation-aware cloud lifecycle
The control plane SHALL distinguish suspend, disable and terminate operations and reconcile media, evidence, versions, jobs and credentials before reporting resource deletion complete.

#### Scenario: Held footage during termination
- **WHEN** termination encounters an accepted hold or active export
- **THEN** deletion SHALL wait for an explicit permitted disposition
- **AND** generic provider purge SHALL not delete protected media
- **AND** final cleanup SHALL verify storage/version absence and key revocation
