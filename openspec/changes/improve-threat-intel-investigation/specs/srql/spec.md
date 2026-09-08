## ADDED Requirements

### Requirement: SRQL Threat Intel Matches Entity

SRQL SHALL provide `in:threat_intel_matches` as a queryable current IP/CIDR match
entity backed by live cache endpoints and active individual indicators. Results
SHALL expose deterministic match identity, match kind, observed IP, indicator
identity/value/type, source, label, severity, confidence, cache evaluation and
expiry, indicator validity, and optional unambiguous source-object context.

#### Scenario: Query current OTX matches

- **GIVEN** a live cached endpoint matches an active AlienVault OTX indicator
- **WHEN** a client runs
  `in:threat_intel_matches source:alienvault_otx sort:evaluated_at:desc limit:100`
- **THEN** SRQL SHALL return one row for that endpoint-to-indicator membership
- **AND** the row SHALL identify cache evaluation separately from flow evidence
  observation time

#### Scenario: One endpoint matches overlapping indicators

- **GIVEN** one endpoint is contained by two active indicator CIDRs
- **WHEN** a client queries `in:threat_intel_matches`
- **THEN** SRQL SHALL return two deterministic match rows
- **AND** pagination SHALL not duplicate or omit either row

#### Scenario: Expired data is queried

- **GIVEN** a cache row or indicator is expired
- **WHEN** a client runs the default threat match query
- **THEN** SRQL SHALL exclude the expired match
- **AND** an explicitly supported stale/debug filter SHALL label stale rows rather
  than mixing them into current results

### Requirement: SRQL Flow Threat Filters

SRQL `in:flows` and `in:attributed_flows` SHALL support identical
`threat_matched`, `threat_source`, `threat_indicator`,
`threat_observed_ip`, and `threat_severity` filters and SHALL expose bounded
source/destination threat summaries without duplicating flow rows.

#### Scenario: Query all currently threat-matched flows

- **GIVEN** current cache matches exist for flow endpoints
- **WHEN** a client runs
  `in:flows threat_matched:true time:last_24h sort:time:desc limit:100`
- **THEN** SRQL SHALL return only flows whose source or destination endpoint has a
  live match
- **AND** each flow SHALL appear once even when an endpoint matches multiple
  indicators

#### Scenario: Query flows for one indicator

- **GIVEN** an active indicator covers endpoints present in recent flows
- **WHEN** a client filters `in:flows` with `threat_indicator` and a bounded time
  range
- **THEN** SRQL SHALL return flows involving an endpoint matched by that indicator
- **AND** it SHALL parameterize the indicator value rather than interpolate it
  into SQL

#### Scenario: Query attributed threat-matched flows

- **GIVEN** a threat-matched flow contains persisted process attribution
- **WHEN** a client runs
  `in:attributed_flows threat_source:alienvault_otx time:last_24h`
- **THEN** SRQL SHALL apply the same threat-source semantics as `in:flows`
- **AND** it SHALL preserve process, agent, container, and workload attribution
  fields

#### Scenario: Multiple indicators match one flow endpoint

- **GIVEN** a flow endpoint matches multiple active indicators
- **WHEN** a threat-aware flow query returns the flow
- **THEN** the flow SHALL appear once
- **AND** its source/destination summary SHALL report the bounded indicator-match
  count, maximum severity, and distinct sources

### Requirement: SRQL Threat Query Bounds And Failure Fidelity

Interactive SRQL threat-aware flow queries SHALL use bounded time and result
windows, index-backed endpoint-first plans, typed validation, and explicit timeout
errors.

#### Scenario: Threat flow query omits time

- **GIVEN** a client runs an interactive threat-aware flow query without a time
  predicate
- **WHEN** SRQL plans the query
- **THEN** it SHALL apply the documented bounded default time window or reject the
  request with a typed error
- **AND** it SHALL NOT scan all retained flow history synchronously

#### Scenario: Threat filter uses unsupported operator

- **GIVEN** a threat filter uses an unsupported operator or malformed IP/CIDR
- **WHEN** SRQL parses or plans the query
- **THEN** it SHALL return a typed invalid-request error
- **AND** it SHALL execute no fallback string-interpolated SQL

#### Scenario: Database cancels threat query

- **GIVEN** PostgreSQL cancels a threat query at statement timeout
- **WHEN** SRQL returns the result
- **THEN** it SHALL return an explicit query-timeout error
- **AND** it SHALL NOT translate the failure into an empty successful result set

### Requirement: SRQL Threat Intel Read Authorization

SRQL threat-match entities and threat-aware flow filters SHALL enforce the same
deployment scope and `observability.netflow.view` authorization as ordinary
NetFlow reads.

#### Scenario: User lacks NetFlow read permission

- **GIVEN** a user lacks `observability.netflow.view`
- **WHEN** the user queries `in:threat_intel_matches` or a threat-aware flow
  filter
- **THEN** SRQL SHALL deny the query
- **AND** it SHALL return no endpoint, indicator, or source-object data
