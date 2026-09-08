## ADDED Requirements

### Requirement: MCP exposes a device identity trace tool
The MCP server SHALL provide a `trace_device_identity` tool that accepts a device `uid`, `ip`, or `hostname` and returns, in one response: the current device record including tombstone fields, the canonical merge chain in both directions, revival audit events, identifier ownership with the currency projection, and the identity evidence component with its cross-partition flag. Non-uid seeds SHALL be resolved to a device uid through a bound device query that includes tombstoned devices. The tool SHALL be read-only and SHALL NOT expose merge, unmerge, delete, or restore operations.

#### Scenario: Trace a tombstoned device to its survivor
- **GIVEN** device `sr:aaa` was merged into `sr:bbb` and subsequently tombstoned
- **WHEN** an operator calls `trace_device_identity` with `uid` `sr:aaa`
- **THEN** the response SHALL include the merge edge to `sr:bbb` with its reason, source, and timestamp
- **AND** the response SHALL include the tombstone `deleted_at`, `deleted_by`, and `deleted_reason`
- **AND** the operator SHALL NOT need to know the storage schema to obtain this

#### Scenario: Trace by hostname resolves the seed first
- **GIVEN** a tombstoned device whose hostname is `farm01`
- **WHEN** an operator calls `trace_device_identity` with `hostname` `farm01`
- **THEN** the tool SHALL resolve the hostname to a device uid through a bound device query that includes tombstoned devices
- **AND** the tool SHALL return the trace for that uid

#### Scenario: Identifier currency is reported in the trace
- **GIVEN** the traced device owns one MAC identifier matching its current facts and one that does not
- **WHEN** an operator calls `trace_device_identity`
- **THEN** the identifier section SHALL report `matches_current_facts` per identifier
- **AND** the operator SHALL be able to distinguish current corroborated ownership from a historical identifier

#### Scenario: Trace reports cross-partition evidence
- **GIVEN** the traced device is connected by shared identifier evidence to a device in another partition
- **WHEN** an operator calls `trace_device_identity`
- **THEN** the evidence section SHALL flag the cross-partition edge
- **AND** the evidence section SHALL distinguish direct evidence from transitive connectivity

### Requirement: MCP exposes a reconciliation run explanation tool
The MCP server SHALL provide an `explain_identity_reconciliation` tool that accepts a `run_id` or a time range and returns reconciliation run summaries including candidates, mergeable components, blocked components, largest blocked component, merges attempted, errors, the configured per-run cap, and whether the cap was reached. The tool SHALL return the device membership of blocked components, and on request the identity evidence edges for one named component. The tool SHALL be read-only.

#### Scenario: Explain why a run stopped early
- **GIVEN** the most recent reconciliation run performed merges equal to its configured cap
- **WHEN** an operator calls `explain_identity_reconciliation` for the last 24 hours
- **THEN** the response SHALL report the configured cap, the merges performed, and that the cap was reached

#### Scenario: Explain a blocked component
- **GIVEN** a run classified an ambiguous transitive component as blocked
- **WHEN** an operator calls `explain_identity_reconciliation` with that run and component
- **THEN** the response SHALL list the component device uids
- **AND** the response SHALL include the evidence edges distinguishing direct evidence from transitive connectivity

#### Scenario: A failed run is explained rather than absent
- **GIVEN** a reconciliation run raised and was rescued
- **WHEN** an operator calls `explain_identity_reconciliation` for the covering time range
- **THEN** the response SHALL include the failed run with its status and error summary

### Requirement: Identity diagnostic tools bind scalar parameters
The `trace_device_identity` and `explain_identity_reconciliation` tools SHALL treat `uid`, `ip`, `hostname`, `run_id`, and component identifiers as bound scalar values through the shared parameter binding mechanism, and SHALL NOT concatenate them into SRQL fragments.

#### Scenario: Injection payload in a uid cannot widen the trace
- **GIVEN** a `trace_device_identity` request whose `uid` contains quotes and boolean operators
- **WHEN** the server constructs its SRQL queries
- **THEN** the payload SHALL be bound as a single value
- **AND** the query structure SHALL be unchanged by the input

#### Scenario: Injection payload in a hostname cannot escape its filter
- **GIVEN** a `trace_device_identity` request whose `hostname` contains SRQL operators
- **WHEN** the server constructs the seed resolution query
- **THEN** the hostname SHALL be bound as a single value and SHALL NOT terminate or extend the filter expression

### Requirement: Identity diagnostic tools enforce the SRQL permission gate
The identity diagnostic tools SHALL execute through the same SRQL path as `execute_srql`, so that the `devices.view` entity permission gate and the projection redaction rules are applied once and cannot be bypassed by calling a tool instead of submitting a query.

#### Scenario: Caller without devices.view is refused by the tool
- **GIVEN** an authenticated MCP caller holding `settings.mcp.manage` but not `devices.view`
- **WHEN** that caller invokes `trace_device_identity`
- **THEN** the call SHALL be rejected as forbidden
- **AND** no identity diagnostic data SHALL be returned

#### Scenario: Redaction applies to tool output
- **GIVEN** a merge audit record whose `details` jsonb carries an unrecognized key
- **WHEN** that record is returned through `trace_device_identity`
- **THEN** the unrecognized key SHALL be absent from the tool response
