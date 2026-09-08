# srql

## ADDED Requirements

### Requirement: Sweep diagnostics entities

SRQL SHALL expose read-only entities covering sweep configuration, execution and
per-host results, so that every sweep group and scanner profile targeting a
device can be identified from the query surface.

#### Scenario: Identify what targets a device
- **GIVEN** a device targeted by more than one sweep group
- **WHEN** an operator queries the sweep entities for that device
- **THEN** every sweep group targeting it SHALL be listed
- **AND** each SHALL report its target query, partition, assigned agents,
  scanner profile, interval and enabled state

#### Scenario: Query results by vantage point without loss
- **GIVEN** one device swept by two agents
- **WHEN** an operator groups sweep results by agent
- **THEN** each agent's result SHALL be returned separately
- **AND** no agent's result SHALL be absent because another agent reported later

#### Scenario: Distinguish requested from observed protocols
- **GIVEN** a sweep group requesting both ICMP and TCP
- **WHEN** an operator queries the per-host results
- **THEN** the requested sweep modes SHALL be visible alongside the observed
  per-mode outcome
- **AND** scanned ports SHALL be visible alongside open ports, so a refused port
  is distinguishable from a port that was never attempted

#### Scenario: Query execution history
- **GIVEN** a sweep group that has run repeatedly
- **WHEN** an operator queries its executions
- **THEN** each execution SHALL report status, start and completion time,
  duration, host totals, the agent that ran it and the config version in force

#### Scenario: Unknown sweep entity is a query error
- **GIVEN** a misspelled sweep entity name
- **WHEN** the query is compiled
- **THEN** it SHALL fail in the SRQL compiler as an unknown entity
- **AND** SHALL NOT be reported as a permission denial

### Requirement: Sweep overlap and last-writer diagnostics

SRQL SHALL expose a diagnostic entity that reports, for a device, every sweep
group and agent targeting it together with which of them currently owns the
device availability record.

#### Scenario: Detect overlapping sweep groups
- **GIVEN** a device targeted by two sweep groups through the same agent
- **WHEN** an operator queries the overlap entity for that device
- **THEN** both sweep groups SHALL be reported
- **AND** the scanner profile and requested modes of each SHALL be reported

#### Scenario: Identify the last writer
- **GIVEN** overlapping sweep groups whose availability records collide on the
  device and agent key
- **WHEN** an operator queries the overlap entity
- **THEN** the entity SHALL identify which sweep group and execution last wrote
  the surviving availability record
- **AND** the operator SHALL be able to tell that the displayed availability does
  not represent every group targeting that device

#### Scenario: Restricted scanner profiles are masked, not dropped
- **GIVEN** a sweep group whose scanner profile is flagged `admin_only`
- **AND** a user holding only `networks.sweeps.view`
- **WHEN** that user queries the overlap entity
- **THEN** the row SHALL still be reported, because "this group declared the
  device and never swept it" is the diagnostic the entity exists to raise and is
  equally the operator's business whichever profile stands behind it
- **AND** the scanner profile name and profile id SHALL be reported as null,
  because `admin_only` is a row-level read restriction that the profile entity
  already enforces and a view joining the same table SHALL NOT bypass it

#### Scenario: Declared-but-unobserved rows are reachable by default
- **GIVEN** a result set mixing observed rows with declared-but-unobserved rows,
  whose last-seen timestamp is null by construction
- **WHEN** an operator queries the overlap entity without an explicit sort
- **THEN** the declared-but-unobserved rows SHALL be ordered ahead of the
  observed rows, so they are not buried behind a prefix longer than the maximum
  cursor offset
- **AND** every default query surface built over this entity SHALL leave that
  ordering in place rather than substituting a single-column sort

#### Scenario: A time window is refused rather than ignored
- **GIVEN** a query against the overlap entity carrying a time window
- **WHEN** the query is compiled
- **THEN** it SHALL be rejected
- **AND** the window SHALL NOT be silently discarded, because the only timestamp
  available to bind it to is null on exactly the declared-but-unobserved rows the
  entity exists to surface

### Requirement: Compiled sweep config exposure excludes credentials

SRQL SHALL expose the effective compiled sweep configuration delivered to an
agent through a named-column allowlist, and SHALL NOT expose the stored
compiled config document.

#### Scenario: Compiled sweep settings are queryable
- **GIVEN** an agent that has received a compiled sweep configuration
- **WHEN** an operator queries the compiled sweep config entity
- **THEN** the sweep group, scanner profile, effective ports, effective modes,
  interval and enabled state SHALL be returned
- **AND** an operator SHALL be able to see when a requested mode was dropped
  during compilation

#### Scenario: Credential material is structurally unreachable
- **GIVEN** stored compiled configurations that include SNMP and mapper output
  carrying credential material
- **WHEN** the compiled sweep config entity is queried
- **THEN** only sweep configuration instances SHALL be selected
- **AND** the compiled config document SHALL NOT be projected in any form
- **AND** no credential material SHALL be returned

#### Scenario: Widening the projection fails a test
- **GIVEN** the allowlist of columns the entity exposes
- **WHEN** a change adds a column to that projection
- **THEN** an automated test SHALL fail
- **AND** the failure SHALL occur before the field can be published

#### Scenario: Compiled sweep config is admin scoped
- **GIVEN** a caller without administrative scope
- **WHEN** they query the compiled sweep config entity
- **THEN** the query SHALL be denied

### Requirement: Sweep coverage history entity

SRQL SHALL expose the per-day sweep coverage rollup so that overlap and
attribution remain queryable beyond the raw host result retention window.

#### Scenario: Query coverage beyond raw retention
- **GIVEN** sweep activity older than the raw host result retention window
- **WHEN** an operator queries the coverage entity for a device
- **THEN** per-day counts, port sets and mode sets SHALL be returned per sweep
  group and agent

#### Scenario: Coverage retains group and agent separation
- **GIVEN** a device swept by two groups on the same day
- **WHEN** the coverage entity is queried
- **THEN** the two groups SHALL be reported as separate rows

### Requirement: Entity permission gate resolves the entity positionally

The SRQL entity permission gate SHALL identify the queried entity the same way
the parser does, regardless of where the `in:` token appears in the query.

#### Scenario: Entity token is not first
- **GIVEN** a caller lacking the permission for an admin-scoped entity
- **WHEN** they submit a query whose `in:` token is not the first token, such as
  `limit:1 in:sweep_compiled_config`
- **THEN** the gate SHALL resolve the entity and deny the query
- **AND** the denial SHALL match the denial for the same query with `in:` first

#### Scenario: Gate and parser agree on the entity
- **GIVEN** any query the parser accepts
- **WHEN** the gate extracts the entity
- **THEN** it SHALL extract the same entity the parser resolves
- **AND** a query SHALL NOT reach the compiler having skipped the gate because
  of token order

### Requirement: Sweep coverage queries span the rollup retention

SRQL SHALL allow a time window over the sweep coverage entity that reaches the
full rollup retention, rather than the shorter default window applied to
entities with no long-lived history.

#### Scenario: Query older than the default window cap
- **GIVEN** coverage rows retained for longer than the default maximum query
  window
- **WHEN** an operator queries the coverage entity across that longer span
- **THEN** the query SHALL be accepted
- **AND** SHALL return the rolled-up rows for the requested window

#### Scenario: Raw result entities keep the default cap
- **GIVEN** the per-host result entity, whose rows are short-lived
- **WHEN** a query requests a window longer than the default cap
- **THEN** the existing cap SHALL still apply
