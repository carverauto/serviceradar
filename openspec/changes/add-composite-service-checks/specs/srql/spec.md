## ADDED Requirements

### Requirement: Composite Verdict Device Fields

SRQL SHALL expose each composite check's verdict as a device field addressed by
the check's slug, using the same dotted-key token shape as device tags.

`composite.<slug>` SHALL filter on the verdict slug and
`composite.<slug>.status` SHALL filter on the fixed status enum. Devices with no
result row for a check SHALL NOT match a verdict or status filter for it.

The filter SHALL be compiled as a correlated subquery rather than a join,
because composite results live in a separate table from devices while the
device query selects from the device table alone.

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

#### Scenario: Unknown slug never widens the result set

- **WHEN** a query filters on a composite slug that does not exist
- **THEN** the compiled filter SHALL match no devices
- **AND** SHALL NOT silently return every device

#### Scenario: Unknown slug is reported to the caller

- **GIVEN** a caller that validates a query before running it
- **WHEN** the query references a composite slug with no matching check
- **THEN** validation SHALL fail with an error naming the unknown slug

### Requirement: Composite Slug Validation Boundary

Slug existence SHALL be validated where a database connection is available, not
in the query translator. The translator is a pure query compiler and cannot know
which checks exist.

#### Scenario: Translation does not require knowing the slug set

- **WHEN** a query referencing any syntactically valid composite slug is
  translated
- **THEN** translation SHALL succeed without consulting stored checks

#### Scenario: A malformed composite field is rejected at translation

- **WHEN** a query references a composite field whose slug is not slug-shaped
- **THEN** translation SHALL fail with an error naming the field

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
