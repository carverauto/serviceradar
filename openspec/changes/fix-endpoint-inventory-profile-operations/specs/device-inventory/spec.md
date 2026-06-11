## ADDED Requirements

### Requirement: Device Details Software Tab
The device details experience SHALL expose endpoint software inventory in a dedicated Software tab.

#### Scenario: Device details includes Software tab
- **GIVEN** an operator opens a device details page
- **WHEN** the device details navigation is rendered
- **THEN** a Software tab SHALL be available for endpoint package inventory
- **AND** endpoint package inventory SHALL NOT be presented only in generic profile, raw event, or miscellaneous detail panels

#### Scenario: Software tab shows package inventory
- **GIVEN** a device has a latest successful endpoint inventory scan with package rows
- **WHEN** the operator opens the Software tab
- **THEN** the tab SHALL show package count, freshness, package manager breakdown, and package rows
- **AND** the operator SHALL be able to filter by package name, version, package manager, PURL, and CPE where available

### Requirement: Software Tab Reports Inventory Coverage
The Software tab SHALL show scan coverage and scanner diagnostics alongside package rows.

#### Scenario: Low package count with complete coverage
- **GIVEN** a device reports only a small number of packages
- **AND** scanner diagnostics show all enabled entries completed successfully
- **WHEN** the operator opens the Software tab
- **THEN** the tab SHALL display the low package count as complete inventory

#### Scenario: Low package count with partial coverage
- **GIVEN** a device reports only a small number of packages
- **AND** scanner diagnostics show one or more enabled entries failed, were skipped unexpectedly, timed out, or were truncated
- **WHEN** the operator opens the Software tab
- **THEN** the tab SHALL display the inventory as partial
- **AND** it SHALL show the failing or skipped diagnostic entries and reasons

#### Scenario: No package rows are available
- **GIVEN** a device has no endpoint package rows
- **WHEN** the operator opens the Software tab
- **THEN** the tab SHALL distinguish not assigned, assigned but not delivered, delivered but no scan yet, stale scan, failed scan, and unsupported agent states where known

### Requirement: Device Software State Traces To Assignment
Device software inventory SHALL be traceable back to endpoint inventory profile, assignment, and config delivery state where available.

#### Scenario: Device inventory traces to profile
- **GIVEN** endpoint inventory is enabled for a device through an add-on profile
- **WHEN** the operator opens the device Software tab
- **THEN** the tab SHALL show the source profile and assignment state
- **AND** it SHALL show whether config delivery to the reporting agent is pending or delivered when that state is known

#### Scenario: Device has no enrolled agent
- **GIVEN** a device matches an endpoint inventory profile query but has no enrolled agent
- **WHEN** the operator opens the Software tab
- **THEN** the tab SHALL report that endpoint inventory cannot run until an agent is enrolled or associated with the device
