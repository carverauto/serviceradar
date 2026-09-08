## ADDED Requirements

### Requirement: NetFlow Threat Match Read Semantics

NetFlow threat-intel surfaces SHALL represent current IP/CIDR matching as live,
expiring endpoint-to-indicator state and SHALL keep that state distinct from
persisted historical flow evidence and canonical security findings.

#### Scenario: Current endpoint is in the threat cache

- **GIVEN** a recent source or destination IP is contained by an active indicator
- **WHEN** the current matching worker refreshes threat state
- **THEN** the system SHALL maintain a live endpoint cache row with evaluation
  time, expiry, distinct sources, maximum severity, and indicator-match count
- **AND** investigation detail SHALL resolve the individual matching indicators
  through the indexed indicator path

#### Scenario: Cache count is displayed

- **GIVEN** a cache row reports `match_count = 3`
- **WHEN** a NetFlow or dashboard surface displays the value
- **THEN** it SHALL label the value as three indicator matches
- **AND** it SHALL NOT label the value as three flows, occurrences, or findings

#### Scenario: Current match expires

- **GIVEN** the matching worker no longer refreshes an endpoint before cache expiry
- **WHEN** a current-match query runs
- **THEN** the endpoint SHALL no longer be presented as a current match
- **AND** any persisted retrohunt evidence SHALL remain independently available

### Requirement: NetFlow Threat Context Supports Investigation Pivots

Normal and attributed NetFlow surfaces SHALL accept threat-intel match filters and
preserve threat context when an operator pivots from dashboard or match detail.

#### Scenario: Dashboard match opens matching traffic

- **GIVEN** the operator selected an endpoint-to-indicator match
- **WHEN** the operator opens matching traffic
- **THEN** the NetFlow query SHALL preserve the endpoint, indicator or source, and
  bounded time window
- **AND** the flow detail SHALL show which endpoint carried the threat match

#### Scenario: Attributed traffic preserves both contexts

- **GIVEN** a selected threat match overlaps an attributed flow
- **WHEN** the operator opens the attributed-flow pivot
- **THEN** the result SHALL show threat state alongside process, agent, container,
  and workload context
- **AND** selecting the row SHALL retain both contexts in flow detail

### Requirement: NetFlow Threat Queries Are Endpoint-First And Bounded

Interactive NetFlow threat queries SHALL resolve candidate endpoints through the
live match cache before resolving individual indicators and SHALL use bounded time,
result, and statement-timeout budgets.

#### Scenario: Interactive matched-flow search is planned

- **GIVEN** a threat-aware flow query over a bounded recent window
- **WHEN** the database plan is generated
- **THEN** it SHALL use exact cached-endpoint and flow time/endpoint paths before
  indexed CIDR detail resolution
- **AND** it SHALL NOT perform an unconstrained full-flow-by-full-indicator join

#### Scenario: Operator requests a long historical window

- **GIVEN** the requested window exceeds the documented interactive bound
- **WHEN** the operator starts the search
- **THEN** the UI SHALL direct the operator to resumable retrohunt execution or
  return a typed bounded-query error
- **AND** it SHALL NOT hold a synchronous LiveView database request for the full
  historical scan
