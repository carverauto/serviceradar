## ADDED Requirements

### Requirement: Threat Intelligence Investigation Workspace

The system SHALL provide an authenticated threat-intelligence investigation
workspace that lets an authorized operator browse current endpoint-to-indicator
matches, inspect individual match context, review historical retrohunt evidence,
and distinguish both from imported-only indicator inventory.

#### Scenario: Operator opens current matches

- **GIVEN** live IP threat-intel cache rows match active indicators
- **WHEN** an operator with `observability.netflow.view` opens
  `/security/threat-intel`
- **THEN** the workspace SHALL show a deterministic paginated list of current
  endpoint-to-indicator matches
- **AND** it SHALL identify the observed endpoint, indicator, source, label,
  severity, confidence, cache evaluation time, and expiry where available

#### Scenario: Imported indicator has no local match

- **GIVEN** an indicator exists in imported inventory but no live cache or
  retrohunt evidence matches local telemetry
- **WHEN** the operator browses the inventory
- **THEN** the system SHALL label it as imported-only
- **AND** it SHALL NOT count or describe it as a local sighting, flow hit, or
  security finding

#### Scenario: Current match and retrohunt evidence remain distinct

- **GIVEN** one endpoint has a current cache match and a historical retrohunt row
- **WHEN** the operator views that endpoint
- **THEN** the current match SHALL label its cache evaluation time and expiry
- **AND** the retrohunt evidence SHALL separately show its persisted observation
  window, direction, evidence count, bytes, and packets

#### Scenario: Provider context is unavailable

- **GIVEN** a matched indicator has no unambiguous source-object relationship
- **WHEN** the operator opens match detail
- **THEN** the UI SHALL state that provider context is unavailable
- **AND** it SHALL NOT infer a pulse or object from a label or unrelated record

### Requirement: Honest Threat Match Metrics

Threat-intel summary metrics SHALL distinguish distinct matched endpoints,
endpoint-to-indicator memberships, and flow evidence occurrences.

#### Scenario: One endpoint matches two indicators

- **GIVEN** one cached endpoint is contained by two active indicator CIDRs
- **WHEN** the dashboard and investigation summary render
- **THEN** `Matched IPs` SHALL equal one
- **AND** `Indicator matches` SHALL equal two
- **AND** neither metric SHALL be labeled as two matching flows or two findings

#### Scenario: Retrohunt evidence has an occurrence count

- **GIVEN** a retrohunt finding persists an evidence count of ten
- **WHEN** the finding is rendered
- **THEN** the UI MAY label ten flow evidence occurrences
- **AND** it SHALL keep that evidence count separate from current cache
  indicator-match counts

### Requirement: Threat Match Flow Pivots

The investigation workspace SHALL provide shareable pivots from a selected
endpoint-to-indicator match to bounded NetFlow and attributed-flow SRQL searches.

#### Scenario: Pivot to matching flows

- **GIVEN** an operator selects a current match with an observed IP, indicator,
  source, and active time window
- **WHEN** the operator activates `View flows`
- **THEN** the system SHALL navigate to an `in:flows` search constrained by the
  selected threat context and a bounded time range
- **AND** the URL SHALL preserve enough query state to share or reload the search

#### Scenario: Pivot to attributed matching flows

- **GIVEN** an operator selects a current match
- **WHEN** the operator activates `View attributed flows`
- **THEN** the system SHALL navigate to an `in:attributed_flows` search with the
  same threat and time constraints
- **AND** returned rows SHALL retain their process, agent, and workload
  attribution context

### Requirement: Threat Investigation Failure Fidelity

The investigation workspace SHALL distinguish no data, stale data, authorization
failure, and query failure.

#### Scenario: Query reaches statement timeout

- **GIVEN** a threat match or flow query exceeds its database statement timeout
- **WHEN** the request completes with a query-canceled error
- **THEN** the workspace SHALL show an explicit query timeout state and retry
  action
- **AND** it SHALL NOT show `No matches` or a zero count for the failed query

#### Scenario: Cached match is expired

- **GIVEN** a cache row has expired
- **WHEN** the operator opens the default current-match view
- **THEN** the expired row SHALL be excluded
- **AND** any explicit stale/debug view SHALL visibly label the row stale

### Requirement: Threat Investigation Authorization And Redaction

Threat-intel investigation reads SHALL require
`observability.netflow.view`; configuration mutations SHALL continue to require
`plugins.assign`; and investigation outputs SHALL exclude provider credentials and
secret material.

#### Scenario: Read-only operator investigates a match

- **GIVEN** a user has `observability.netflow.view` but not `plugins.assign`
- **WHEN** the user opens `/security/threat-intel`
- **THEN** the user SHALL be able to inspect matches and pivot to flows
- **AND** the user SHALL NOT be able to modify provider settings or assignments

#### Scenario: Unauthorized user requests threat matches

- **GIVEN** a user lacks `observability.netflow.view`
- **WHEN** the user requests the LiveView, SRQL entity, or backing API
- **THEN** the system SHALL deny the request
- **AND** it SHALL return no endpoint, indicator, source-object, or secret data

#### Scenario: Match result is serialized

- **GIVEN** a threat match includes provider and source-object context
- **WHEN** it is rendered or returned by SRQL
- **THEN** the result SHALL NOT include API keys, secret references, raw archived
  payloads, or unredacted provider errors
