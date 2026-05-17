## ADDED Requirements

### Requirement: Device details metadata cards prioritize operator-useful facts
The device details UI SHALL render metadata as source-specific, operator-useful cards and SHALL hide redundant, implementation-only, debug, or transport fields from the primary page by default.

The page SHALL NOT show an Aliases summary card when the full IP aliases table is already present. It SHALL NOT show an "Other Metadata" card that only reports a hidden key count without a way to inspect useful fields. Source-specific cards such as MikroTik, UniFi, SNMP, Armis, or NetBox SHALL appear only when the displayed fields apply to the device and are useful for identification, ownership, location, role, risk, or operational status.

#### Scenario: Alias table replaces alias summary
- **GIVEN** a device has IP aliases
- **AND** the device details page includes the full alias table
- **WHEN** the metadata cards render
- **THEN** the UI SHALL omit the separate Aliases summary card
- **AND** users SHALL inspect alias state in the full alias table

#### Scenario: Integration card hides transport and implementation fields
- **GIVEN** a UniFi router has integration metadata that includes API URLs, mapper job IDs, discovery IDs, and SNMP identity fields
- **WHEN** device details metadata renders
- **THEN** the primary cards SHALL show useful identity and SNMP facts such as system name, location, owner/contact, description, vendor/model, and role when present
- **AND** the primary cards SHALL hide API URLs, mapper job IDs, discovery IDs, debug payloads, and hidden-key counts by default
- **AND** a MikroTik card SHALL NOT render as primary content unless the device has MikroTik-specific facts that apply to that device

### Requirement: Device details availability matches sweep evidence
The device details UI SHALL ensure Agent Availability is consistent with the persisted sweep observations shown in Recent Sweep History.

When recent sweep history exists but no per-agent availability rollup exists, the UI SHALL explain the missing rollup as a data-pipeline condition and SHALL not present it as if no availability evidence exists.

#### Scenario: Recent sweep history drives agent availability
- **GIVEN** a device has recent sweep history from `agent-dusk01` showing Available
- **WHEN** the device details page renders Agent Availability
- **THEN** Agent Availability SHALL show `agent-dusk01` with the latest available observation or an explicit stale/freshness state
- **AND** it SHALL NOT say no per-agent sweep availability has been recorded

#### Scenario: Sweep rows exist but rollup is missing
- **GIVEN** a device has Recent Sweep History rows
- **AND** the per-agent availability rollup table or projection has no matching row
- **WHEN** Agent Availability renders
- **THEN** the UI SHALL explain that sweep history exists but the availability rollup is missing or stale
- **AND** the page SHALL show enough context to diagnose the ingestion/rollup mismatch

### Requirement: Device logs tab uses bounded SRQL results and terminal empty states
The device details Logs tab SHALL execute a bounded SRQL-backed query for logs associated with the current device and render the result set directly.

If the query returns zero rows, the tab SHALL render a terminal empty state with the current filter context and a link to the full logs view. The tab SHALL NOT keep showing a loading state or emit timeout toasts merely because no logs exist.

#### Scenario: Device has no matching logs
- **GIVEN** a device has no log rows for the current log query window
- **WHEN** the user opens the Logs tab
- **THEN** the UI SHALL run the bounded SRQL query
- **AND** it SHALL render zero rows with a clear empty state
- **AND** it SHALL keep the "Open full logs view" link using the same device filter context
- **AND** it SHALL NOT show a timeout toast or indefinite loader

#### Scenario: Device has matching logs
- **GIVEN** a device has log rows matching its canonical identity or selected alias filter
- **WHEN** the user opens the Logs tab
- **THEN** the UI SHALL render the bounded result rows
- **AND** the full logs view link SHALL preserve the same device/log filter context
