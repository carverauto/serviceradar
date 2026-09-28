## MODIFIED Requirements

### Requirement: MCP exposes a device identity trace tool
The MCP server SHALL provide a `trace_device_identity` tool that accepts a device `uid`, `ip`, or `hostname` and returns, in one response: the current device record including tombstone fields, the canonical merge chain in both directions, revival audit events, identifier ownership with the currency projection, the identity evidence component with its cross-partition flag, the identity decisions naming the device, and the de-duplication tasks naming the device with their status. Non-uid seeds SHALL be resolved to a device uid through a bound device query that includes tombstoned devices. The tool SHALL be read-only and SHALL NOT expose merge, unmerge, delete, restore, or task resolution operations.

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

#### Scenario: Trace reports why two devices were not merged
- **GIVEN** the merge policy refused to merge the traced device with another device, and the refusal opened a de-duplication task
- **WHEN** an operator calls `trace_device_identity`
- **THEN** the response SHALL include the identity decision with its kind and reason
- **AND** the response SHALL include the task and report it as open
