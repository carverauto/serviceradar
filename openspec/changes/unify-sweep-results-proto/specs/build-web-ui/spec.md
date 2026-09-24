# build-web-ui Delta

## ADDED Requirements

### Requirement: On-demand MTR resolves durable results asynchronously

The UI SHALL treat ControlStream completion and durable MTR projection as
distinct states. A command response SHALL provide a stable trace ID, authoritative
`network_scope_id`, and bounded summary; the UI SHALL subscribe or poll until the
canonical EventWriter trace is queryable or reaches an explicit failed, missing,
quarantined, or timeout state.

Every URL, subscription, poll, and trace/hop query SHALL derive the viewer's
allowed network scopes from authenticated server-side authorization. Trace state
and hop data SHALL resolve by `(network_scope_id, trace_id)`, never by trace ID or
target address alone. Caller-supplied scope text MAY narrow the authenticated
allowed set but SHALL NOT add to it. Equal trace IDs and overlapping RFC1918
addresses in different network scopes SHALL remain distinct and SHALL NOT reveal
existence, state, or hops across an unauthorized scope.

#### Scenario: Probe completes before EventWriter commit

- **GIVEN** an on-demand command reports probe completion, network scope, and a
  trace ID
- **WHEN** the canonical trace is still in the durable ingest pipeline
- **THEN** the UI SHALL display a result-pending state for that exact
  `(network_scope_id, trace_id)`
- **AND** it SHALL load full hop details only when that scoped trace commits

#### Scenario: Trace cannot be projected

- **WHEN** the correlated scoped trace is terminally failed, quarantined, missing
  past its reconciliation deadline, or times out for the viewer
- **THEN** the UI SHALL display the precise state and retry/support context
- **AND** it SHALL NOT show an empty trace as a successful diagnostic

#### Scenario: Equal trace IDs exist in overlapping network scopes

- **GIVEN** two allowed network scopes contain equal trace ID text or the same
  RFC1918 target address
- **WHEN** the viewer polls, subscribes, or opens trace details
- **THEN** the request SHALL identify one allowed `network_scope_id` and query
  only that `(network_scope_id, trace_id)`
- **AND** an omitted scope that would match more than one allowed trace SHALL
  return an explicit ambiguous/not-selected state without trace or hop data

#### Scenario: Caller requests a network scope outside its authorization

- **GIVEN** a route, query parameter, body, or subscription names a
  `network_scope_id` outside the authenticated viewer's allowed set
- **WHEN** the server authorizes the request
- **THEN** it SHALL deny or return not found without querying or disclosing the
  requested trace
- **AND** changing caller-supplied scope text SHALL NOT widen subscriptions or
  subsequent polling requests
