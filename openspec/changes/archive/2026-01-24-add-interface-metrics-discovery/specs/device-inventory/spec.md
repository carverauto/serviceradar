## ADDED Requirements

### Requirement: Interface Available Metrics Storage

The system SHALL store discovered available metrics for each interface in a JSONB `available_metrics` column on the `discovered_interfaces` table.

#### Scenario: Store discovered metrics from mapper
- **GIVEN** an interface discovered via SNMP with available metrics
- **WHEN** the interface is ingested via MapperResultsIngestor
- **THEN** the `available_metrics` JSONB column SHALL contain an array of metric objects
- **AND** each metric object SHALL include `name`, `oid`, `data_type`, and `supports_64bit` fields

#### Scenario: Interface with no metric discovery
- **GIVEN** an interface discovered without OID probing (legacy discovery)
- **WHEN** the interface is ingested via MapperResultsIngestor
- **THEN** the `available_metrics` column SHALL be NULL
- **AND** the interface SHALL remain queryable and displayable

#### Scenario: Query interfaces by available metrics
- **GIVEN** interfaces with various available metrics stored
- **WHEN** a query filters interfaces that support ifHCInOctets (64-bit counters)
- **THEN** only interfaces with `available_metrics` containing `supports_64bit: true` for ifInOctets SHALL be returned

### Requirement: Available Metrics Schema

The `available_metrics` JSONB array SHALL contain objects with the following structure:

```json
{
  "name": "ifInOctets",
  "oid": ".1.3.6.1.2.1.2.2.1.10",
  "data_type": "counter",
  "supports_64bit": true,
  "oid_64bit": ".1.3.6.1.2.1.31.1.1.1.6"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| name | string | yes | Human-readable metric name (e.g., "ifInOctets") |
| oid | string | yes | SNMP OID in dotted notation |
| data_type | string | yes | One of: "counter", "gauge" |
| supports_64bit | boolean | yes | Whether 64-bit (HC) counter is available |
| oid_64bit | string | no | 64-bit OID if supports_64bit is true |

#### Scenario: Metric with 64-bit support
- **GIVEN** an interface that supports both ifInOctets and ifHCInOctets
- **WHEN** available_metrics is stored
- **THEN** the entry SHALL have `supports_64bit: true` and `oid_64bit` populated

#### Scenario: Metric without 64-bit support
- **GIVEN** an interface that only supports ifInErrors (no 64-bit variant)
- **WHEN** available_metrics is stored
- **THEN** the entry SHALL have `supports_64bit: false` and `oid_64bit` SHALL be omitted or null

### Requirement: UI Metrics Selection

The interface details UI SHALL display available metrics for selection when enabling metrics collection.

#### Scenario: Show available metrics dropdown
- **GIVEN** an interface with `available_metrics` containing ifInOctets, ifOutOctets, ifInErrors
- **WHEN** the user views the interface details page and clicks "Enable Metrics"
- **THEN** a dropdown SHALL show only these three metrics as selectable options

#### Scenario: Indicate 64-bit counter availability
- **GIVEN** an interface with ifInOctets supporting 64-bit counters
- **WHEN** the metrics dropdown is displayed
- **THEN** ifInOctets SHALL be visually marked as supporting 64-bit (e.g., "ifInOctets (64-bit)")

#### Scenario: Handle interfaces without discovered metrics
- **GIVEN** an interface with `available_metrics` set to NULL
- **WHEN** the user views the interface details page
- **THEN** a message SHALL indicate "Metric availability unknown"
- **AND** the user SHALL be offered the option to manually configure OIDs or refresh discovery
