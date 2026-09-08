## ADDED Requirements
### Requirement: Device Details Bumblebee Posture Panel
The device details experience SHALL surface Bumblebee developer endpoint exposure posture for devices associated with reporting agents. The panel SHALL show current scan state, source agent, Bumblebee risk contribution, composite risk impact, highest severity, active finding count, catalog snapshot, scanner version, last successful scan time, and coverage state.

#### Scenario: Device with active Bumblebee findings
- **GIVEN** a device has current Bumblebee posture with active findings
- **WHEN** an authorized operator opens the device details view
- **THEN** the UI SHALL show a Security or Supply Chain Exposure panel for Bumblebee
- **AND** the panel SHALL show Bumblebee risk contribution, composite risk impact, highest severity, active finding count, last scan time, catalog snapshot, and source agent

#### Scenario: Composite risk explainability includes Bumblebee
- **GIVEN** Bumblebee contributes to the device composite risk score
- **WHEN** an authorized operator views risk details on the device page
- **THEN** the UI SHALL list Bumblebee as a contributing source
- **AND** show contribution score, active finding count, highest severity, and catalog snapshot provenance

#### Scenario: Inventory risk shows composite score
- **GIVEN** a device has multiple active risk contributions including Armis and Bumblebee
- **WHEN** the device appears in the `/devices` inventory view
- **THEN** the risk column SHALL show the composite risk score and level
- **AND** it SHALL NOT show a lower source-specific score when a higher active contribution exists

#### Scenario: Device has full scan with no findings
- **GIVEN** a device has a completed Bumblebee scan with full coverage and no active findings
- **WHEN** an authorized operator opens device details
- **THEN** the Bumblebee panel SHALL show a clean state for that scan
- **AND** it SHALL include last scan time and catalog snapshot so the operator can judge freshness

#### Scenario: Device has partial coverage
- **GIVEN** a device has a completed Bumblebee scan with partial coverage
- **WHEN** an authorized operator opens device details
- **THEN** the Bumblebee panel SHALL show a partial coverage state rather than a clean state
- **AND** the panel SHALL expose attempted roots, scanned root count, skipped root count, and bounded skipped-root reasons

#### Scenario: Device has never been scanned
- **GIVEN** a device has no completed Bumblebee scan
- **WHEN** an authorized operator opens device details
- **THEN** the Bumblebee panel SHALL show not scanned or unavailable
- **AND** it SHALL NOT imply that the device has no Bumblebee exposure risk

### Requirement: Device Details Bumblebee Findings Drilldown
The device details experience SHALL provide a bounded findings drilldown for active Bumblebee findings without exposing full local package inventory by default.

#### Scenario: Operator expands active findings
- **GIVEN** a device has active Bumblebee findings
- **WHEN** the operator opens the findings drilldown
- **THEN** the UI SHALL show each finding with severity, catalog ID, ecosystem, package name, affected version or version range, evidence summary, first seen, last seen, and status
- **AND** full local package inventory SHALL NOT be displayed unless a later approved change enables inventory retention

#### Scenario: Finding links to observability event
- **GIVEN** a Bumblebee finding has a corresponding observability event
- **WHEN** the finding is shown in device details
- **THEN** the UI SHALL provide a link or action to inspect the normalized observability event with run and catalog provenance
