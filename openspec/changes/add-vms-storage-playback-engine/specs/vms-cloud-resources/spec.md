## ADDED Requirements

### Requirement: Isolated hosted media provisioning
The SaaS control plane SHALL provision or explicitly adopt the private media resources selected by the recording/storage mode through resumable steps, while each ServiceRadar runtime remains a dedicated deployment. Local-only mode SHALL not require object-storage allocation; selected S3 resources SHALL remain purpose-scoped.

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
- **AND** retained receipts SHALL NOT be treated as authenticated historical origin or as storage authority

#### Scenario: Media request targets an installed deployment
- **WHEN** a caller requests qualification submission, qualification status, media installation status or recording configuration
- **THEN** the private listener SHALL require its separately installed media credential and exact deployment reference and generation before parsing a body or accessing receipt storage
- **AND** SHALL reject the account/password-reset credential, missing or duplicate authentication headers, mismatched identities and incomplete installations
- **AND** a successful installation response SHALL identify only the responding process's installed authentication while reporting unavailable readiness and no applied configuration revision
- **AND** the chart SHALL replace pods when the installed reference or generation changes without exposing the listener publicly or embedding secret bytes in values
- **AND** Secret changes or installation responses alone SHALL NOT establish complete rotation, revocation, freshness or provider authority

#### Scenario: Installed origin requests a recording stop
- **WHEN** an authenticated installed origin submits a stop-only recording configuration
- **THEN** the runtime SHALL reject duplicate keys, oversized documents, unsupported fields and positive enable or resume variants
- **AND** SHALL bind the canonical content digest to that origin, preserve exact-retry timestamps and reject stale or conflicting revisions
- **AND** a newer installed generation SHALL require a newer revision without resetting the revision high-water mark
- **AND** status SHALL distinguish enforced stop from full applied configuration, storage readiness and drain completion

### Requirement: Preservation-aware cloud lifecycle
The control plane SHALL distinguish suspend, disable and terminate operations and reconcile media, evidence, versions, jobs and credentials before reporting resource deletion complete.

#### Scenario: Held footage during termination
- **WHEN** termination encounters an accepted hold or active export
- **THEN** deletion SHALL wait for an explicit permitted disposition
- **AND** generic provider purge SHALL not delete protected media
- **AND** final cleanup SHALL verify storage/version absence and key revocation

### Requirement: Private immutable archive registration
The runtime SHALL expose bounded, deployment-authenticated registration of an immutable recording destination through the existing private media administration interface, returning only unqualified binding metadata.

#### Scenario: Provisioning retry preserves identity
- **WHEN** Cloud repeats the exact version 1 destination under the same provisioning reference and generation
- **THEN** registration returns the same product binding ID and destination digest with unavailable readiness
- **AND** no qualification receipt, upload authority or provider operation is created

#### Scenario: Conflicting destination preserves history
- **WHEN** Cloud registers different destination content under an already retained provisioning reference and generation
- **THEN** registration returns a conflict without replacing the retained destination or retargeting existing media

#### Scenario: Registration requires media authentication and bounded exact JSON
- **WHEN** a request lacks the installed media credential and exact deployment identity, uses an unsupported document, contains duplicate keys or exceeds 4096 bytes
- **THEN** registration rejects it before creating a binding
- **AND** account credentials and request-supplied actors cannot authorize registration
