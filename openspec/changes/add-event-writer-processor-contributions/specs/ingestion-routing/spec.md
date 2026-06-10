## ADDED Requirements

### Requirement: Package-contributed EventWriter processors
The ingestion pipeline SHALL allow approved package-backed plugins, native add-ons, and
sidecars to contribute EventWriter processor definitions through package metadata. Core
EventWriter routing SHALL use approved processor contributions and core platform
defaults, not producer-specific aliases or subject clauses for integrations such as
PowerDNS, Falco, Trivy, Bumblebee, or endpoint inventory.

#### Scenario: Add-on package contributes a processor
- **GIVEN** a native add-on package includes a valid EventWriter processor contribution
- **AND** the package version is approved
- **WHEN** EventWriter builds its routing snapshot
- **THEN** the processor contribution SHALL be included in the active routes
- **AND** messages matching its approved subject filters SHALL be processed by the
  declared platform processor engine

#### Scenario: Unapproved contribution is inert
- **GIVEN** a package includes a valid EventWriter processor contribution
- **AND** the package version has not been approved
- **WHEN** EventWriter builds its routing snapshot
- **THEN** the processor contribution SHALL NOT be included in active routes

#### Scenario: Core has no producer-specific alias
- **GIVEN** a PowerDNS package contributes an OCSF DNS Activity processor
- **WHEN** EventWriter processes `pdns.ocsf` messages
- **THEN** routing SHALL resolve through the approved processor registry entry
- **AND** core pipeline code SHALL NOT require a `ServiceRadar.EventWriter.Processors.PowerDNS`
  alias or producer-specific batcher clause

### Requirement: Processor contribution registry snapshots
EventWriter SHALL consume a versioned registry snapshot containing approved processor
contributions, normalized subject filters, processor engine ids, destination metadata,
schema/display references, and device-correlation mappings. Snapshot refresh SHALL be
atomic; if a new snapshot is invalid, EventWriter SHALL keep the previous valid snapshot.

#### Scenario: Registry refresh succeeds
- **GIVEN** a newly approved package processor contribution has no conflicts
- **WHEN** the registry snapshot refreshes
- **THEN** EventWriter SHALL atomically activate the new snapshot
- **AND** subsequent matching messages SHALL use the new route

#### Scenario: Registry refresh fails validation
- **GIVEN** a newly staged processor contribution conflicts with an existing route
- **WHEN** EventWriter validates a refreshed registry snapshot
- **THEN** the refreshed snapshot SHALL be rejected
- **AND** EventWriter SHALL continue processing with the previous valid snapshot
- **AND** the conflict SHALL be visible to operators

### Requirement: Processor subject ownership is validated
The system SHALL validate requested processor subject filters against package ownership
and platform-reserved namespaces before activation. Processor contributions SHALL NOT
claim internal health subjects, unrelated producer subjects, or cross-partition routing
subjects.

#### Scenario: Package claims reserved subject
- **GIVEN** a package processor contribution requests an internal health subject
- **WHEN** the package is validated for approval
- **THEN** validation SHALL fail with a subject ownership error
- **AND** the contribution SHALL NOT become active

### Requirement: Processor contributions use platform-owned engines
Package processor contributions SHALL select platform-owned processor engines and
bounded declarative mappings. They SHALL NOT upload arbitrary Elixir modules, SQL,
JavaScript, native code, or database DDL for EventWriter execution.

#### Scenario: Package attempts executable processor upload
- **GIVEN** a package includes an EventWriter processor contribution that references
  arbitrary executable code
- **WHEN** the package is validated
- **THEN** validation SHALL reject the contribution
- **AND** EventWriter SHALL NOT execute package-supplied code
