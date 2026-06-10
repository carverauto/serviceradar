## ADDED Requirements

### Requirement: Processor contributions normalize package signals
Package-contributed EventWriter processors SHALL normalize package-emitted logs, OCSF
events, security findings, scan activity, and promoted events using bounded
platform-owned processor engines. The normalized records SHALL preserve package signal
schema/display references and gateway/agent-attested provenance.

#### Scenario: PowerDNS emits OCSF DNS Activity
- **GIVEN** the PowerDNS add-on package contributes an `ocsf_passthrough` processor for
  DNS Activity
- **WHEN** a PowerDNS add-on emits an OCSF DNS Activity record
- **THEN** EventWriter SHALL persist the record as an OCSF event
- **AND** the stored event SHALL retain the PowerDNS signal schema/display reference
- **AND** no PowerDNS-specific EventWriter processor module SHALL be required

#### Scenario: Security sidecar emits a finding
- **GIVEN** a Falco, Trivy, Bumblebee, or endpoint inventory package contributes a
  security finding processor
- **WHEN** the sidecar emits a finding payload
- **THEN** EventWriter SHALL normalize it into the appropriate OCSF finding or scan
  activity event
- **AND** the record SHALL remain tied to the originating agent/device through
  attested provenance and declared correlation hints

### Requirement: Declarative signal transforms are bounded
Processor contribution mappings SHALL be limited to bounded field extraction, constants,
enum/severity maps, short templates, and supported OCSF/OTEL destination fields.
Mappings SHALL NOT perform network I/O, SQL, arbitrary code execution, or unbounded
payload expansion.

#### Scenario: Unsupported transform is rejected
- **GIVEN** a processor contribution mapping requests an unsupported operation
- **WHEN** the package is validated
- **THEN** validation SHALL reject the mapping
- **AND** no active EventWriter route SHALL be created for that contribution

#### Scenario: Malformed record is handled safely
- **GIVEN** an approved processor contribution receives a malformed payload
- **WHEN** EventWriter processes the message
- **THEN** the processor engine SHALL drop or store the record according to the
  approved error policy
- **AND** EventWriter SHALL emit telemetry for the malformed record
- **AND** the batch SHALL continue processing other records

### Requirement: Device correlation hints remain non-authoritative
The system SHALL allow processor contributions to declare device-correlation hints using
bounded payload paths and known provenance fields. The correlation engine SHALL combine
those hints with gateway/agent-attested metadata and SHALL NOT treat package-supplied
identity fields as authoritative tenant, partition, or agent identity.

#### Scenario: Package supplies source hostname
- **GIVEN** a package contribution maps `host.hostname` as a device-correlation hint
- **WHEN** EventWriter normalizes a matching event
- **THEN** the stored signal SHALL include correlation candidates for inventory lookup
- **AND** tenant, partition, and agent identity SHALL still come from authenticated
  ingestion provenance

### Requirement: SDKs produce valid signal contribution contracts
The add-on SDK and the Go/Rust plugin SDKs SHALL provide typed helpers for generating
signal schema references, EventWriter processor contributions, OCSF finding mappings,
scan activity mappings, and device-correlation hints. SDK-generated contracts SHALL
validate with the same core schema used during package import.

#### Scenario: Go plugin SDK emits a processor contribution
- **GIVEN** a Go plugin author uses the SDK to declare an OCSF finding processor
- **WHEN** the package manifest is generated
- **THEN** the manifest SHALL include a processor contribution accepted by core
  validation

#### Scenario: Rust plugin SDK emits a scan activity mapping
- **GIVEN** a Rust plugin author uses the SDK to declare a scan activity mapping
- **WHEN** the package manifest is generated
- **THEN** the manifest SHALL include a bounded scan activity contribution accepted by
  core validation
