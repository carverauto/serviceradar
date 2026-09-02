# srql

## ADDED Requirements

### Requirement: Alerts support grouped count aggregation

SRQL SHALL aggregate the alerts entity for
`stats:count() as <alias> by <field>[,<field>]`, returning one row per distinct
combination of the grouped fields with the count projected under the alias.

Groupable fields SHALL be a closed whitelist of triage dimensions: `severity`,
`status`, `source_type`, `device_uid`, `agent_uid`, `metric_name`, and
`escalation_level`.

Results SHALL be ordered by count descending, so a truncated result retains the
largest groups.

Every filter the row path applies SHALL apply identically to the aggregate.

#### Scenario: Count alerts by severity
- **WHEN** a client sends `in:alerts stats:count() as n by severity`
- **THEN** SRQL returns one row per severity with its count
- **AND** the generated SQL groups by the severity column

#### Scenario: Count alerts per device
- **GIVEN** alerts carry a canonical `device_uid`
- **WHEN** a client sends `in:alerts stats:count() as n by device_uid`
- **THEN** SRQL returns one row per device

#### Scenario: Filters apply to the aggregate exactly as to rows
- **WHEN** a client sends `in:alerts severity:critical stats:count() as n by status`
- **THEN** the count covers only critical alerts

#### Scenario: Group by several fields
- **WHEN** a client sends `in:alerts stats:count() as n by severity,status`
- **THEN** SRQL groups by both

### Requirement: An inexpressible alerts aggregation is an error

SRQL SHALL return an error for a `stats:` request against alerts that it cannot
answer, and SHALL NOT fall back to returning alert rows.

Previously the clause was discarded entirely: the SQL was identical to a plain
row query, so a caller asking for counts received a page of rows with a 200 and
no indication the aggregation had been dropped.

#### Scenario: A non-count aggregation is rejected
- **WHEN** a client sends `in:alerts stats:avg(metric_value) as v by severity`
- **THEN** SRQL returns an error
- **AND** SRQL does NOT return alert rows

#### Scenario: An ungroupable field is rejected
- **WHEN** a client groups by `title`
- **THEN** SRQL returns an error naming the unsupported group field

#### Scenario: A stats request with no group is rejected
- **WHEN** a client sends `in:alerts stats:count() as n`
- **THEN** SRQL returns an error rather than a row listing

#### Scenario: An unsafe alias is rejected
- **WHEN** a client supplies an alias containing anything outside `[A-Za-z0-9_]`
- **THEN** SRQL returns an error and generates no SQL containing it

#### Scenario: Row queries are unaffected
- **WHEN** a client sends `in:alerts severity:critical` with no `stats:`
- **THEN** SRQL returns alert rows exactly as before
