## ADDED Requirements

### Requirement: Composite Verdict Device Fields

SRQL SHALL expose each composite check's verdict as a device field addressed by
the check's slug, following the existing dynamic dotted-key convention used for
device tags.

`composite.<slug>` SHALL filter on the verdict slug and
`composite.<slug>.status` SHALL filter on the fixed status enum. Devices with no
result row for a check SHALL NOT match a verdict or status filter for it.

#### Scenario: Filter devices by verdict

- **WHEN** a user runs `in:devices composite.pci-isolation:not_isolated`
- **THEN** the result SHALL contain only devices whose latest verdict for the
  `pci-isolation` check is `not_isolated`

#### Scenario: Filter devices by status

- **WHEN** a user runs `in:devices composite.pci-isolation.status:degraded`
- **THEN** the result SHALL contain only devices whose status for that check is
  `degraded`

#### Scenario: Devices without a result are excluded

- **GIVEN** a device outside the check's scope with no result row
- **WHEN** a verdict filter for that check is applied
- **THEN** the device SHALL NOT appear in the results

#### Scenario: Unknown slug is a query error

- **WHEN** a user filters on a composite slug that does not exist
- **THEN** the query SHALL fail with an error naming the unknown check
- **AND** SHALL NOT silently return every device

### Requirement: Composite Results Entity

SRQL SHALL provide a `composite_results` entity for verdict rollups, filterable
by check and verdict and countable by status.

#### Scenario: Roll up verdicts for a check

- **WHEN** a user runs `in:composite_results check:pci-isolation`
- **THEN** the result SHALL contain one row per device in that check's scope with
  its verdict, status, and evaluation time

#### Scenario: Count devices per verdict

- **WHEN** a rollup is requested for a check
- **THEN** the system SHALL return counts per verdict across the check's scope

### Requirement: Composite Fields In The SRQL Catalog

The SRQL catalog served to the visual query builder SHALL include composite
verdict fields for enabled checks, so that the builder can offer them as
selectable filters.

#### Scenario: Builder offers composite filters

- **GIVEN** an enabled composite check
- **WHEN** the visual query builder loads the device field catalog
- **THEN** the check's verdict field SHALL be offered
- **AND** its selectable values SHALL be that check's authored verdict slugs
