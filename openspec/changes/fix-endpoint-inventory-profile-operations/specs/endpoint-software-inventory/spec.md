## ADDED Requirements

### Requirement: Endpoint Inventory Completeness Depends On Scanner Diagnostics
Endpoint software inventory SHALL determine complete, partial, failed, and unknown scan coverage from scanner diagnostics rather than package count alone.

#### Scenario: Complete scan with expected diagnostics
- **GIVEN** endpoint inventory enables OS package scanner diagnostics
- **WHEN** all enabled and applicable diagnostic entries complete successfully
- **THEN** the resulting scan coverage state SHALL be complete
- **AND** the package count MAY be low without being treated as a failure

#### Scenario: Partial scan with diagnostic failure
- **GIVEN** endpoint inventory enables OS package scanner diagnostics
- **WHEN** at least one applicable enabled diagnostic entry fails, times out, or is truncated
- **THEN** the resulting scan coverage state SHALL be partial
- **AND** the diagnostic reason SHALL be queryable with the scan status

#### Scenario: Unknown coverage from older agent
- **GIVEN** an older agent reports packages without scanner diagnostics
- **WHEN** ingest computes scan coverage
- **THEN** the resulting coverage state SHALL be unknown unless existing metadata proves completeness
- **AND** UI surfaces SHALL avoid presenting the package count as a confirmed complete inventory

### Requirement: Endpoint Inventory Package Counts Are Diagnostic Attributed
Endpoint software inventory SHALL retain package counts by package manager or scanner diagnostic entry for each scan.

#### Scenario: Mixed package managers reported
- **GIVEN** a host reports packages from multiple package managers
- **WHEN** the scan is ingested
- **THEN** the scan status SHALL include package counts grouped by scanner diagnostic entry
- **AND** the total package count SHALL equal the normalized package rows accepted for the scan

#### Scenario: Rejected package rows are reported
- **GIVEN** ingest rejects malformed or out-of-policy package rows
- **WHEN** scan status is stored
- **THEN** the scan diagnostics SHALL include a bounded rejected-row count and reason summary

### Requirement: Endpoint Inventory Profile Coverage Is Queryable
Endpoint software inventory SHALL expose enough assignment and scan state for operators to answer why a device has no or low package inventory.

#### Scenario: Query device endpoint inventory status
- **GIVEN** a device is expected to run endpoint inventory
- **WHEN** the UI or API requests endpoint inventory status for that device
- **THEN** the response SHALL include profile/assignment state, config delivery state when known, last scan coverage, last scan error, and package count

#### Scenario: Query fleet endpoint inventory coverage
- **GIVEN** an operator wants to verify endpoint inventory deployment
- **WHEN** they view profile coverage
- **THEN** the system SHALL expose counts for assigned, delivered, scanned successfully, partial, failed, stale, unsupported, and unassigned matched devices

### Requirement: Endpoint Inventory Feeds Central Vulnerability Matching
Endpoint software inventory SHALL provide normalized package and SBOM evidence for central vulnerability matching without performing feed matching on endpoint agents.

#### Scenario: Current package rows are match inputs
- **GIVEN** endpoint inventory has current package rows for a device
- **WHEN** the central vulnerability matcher runs
- **THEN** it SHALL be able to read package manager, package name, version, architecture, PURL, CPE candidates where available, scan id, device identity, and SBOM artifact reference where available
- **AND** no vulnerability feed data SHALL be required on the agent

#### Scenario: Vulnerability match links back to scan evidence
- **GIVEN** a central vulnerability match is created for a package
- **WHEN** the match is displayed or queried
- **THEN** it SHALL link back to the endpoint inventory scan, package evidence, and SBOM artifact reference where available
- **AND** it SHALL preserve the source feed and coordinate type used for matching
