## MODIFIED Requirements
### Requirement: OCSF Device Type Classification
The system SHALL classify devices using the OCSF type_id enum:
| type_id | type | Description |
|---------|------|-------------|
| 0 | Unknown | Type is unidentified |
| 1 | Server | Server system |
| 2 | Desktop | Desktop computer |
| 3 | Laptop | Laptop computer |
| 4 | Tablet | Tablet device |
| 5 | Mobile | Mobile phone |
| 6 | Virtual | Virtual machine |
| 7 | IOT | Internet of Things device |
| 8 | Browser | Web browser |
| 9 | Firewall | Networking firewall |
| 10 | Switch | Network switch |
| 11 | Hub | Network hub |
| 12 | Router | Network router |
| 13 | IDS | Intrusion detection system |
| 14 | IPS | Intrusion prevention system |
| 15 | Load Balancer | Load balancing device |
| 99 | Other | Unmapped type |

Integration enrichment from systems such as Armis, NetBox, UniFi, SNMP, and mapper profiles SHALL populate canonical `type_id` and `type` when the source provides a recognized type and no stronger local classification already exists. Source-specific type/category values SHALL remain visible as enrichment metadata but SHALL NOT be the only place a recognized device type appears.

#### Scenario: Explicit type from integration
- **GIVEN** a device with category "Firewall" from Armis
- **WHEN** the device is processed by DIRE
- **THEN** the device SHALL have `type_id = 9` and `type = "Firewall"`

#### Scenario: Armis tablet enrichment populates canonical type
- **GIVEN** a device whose Armis enrichment reports type "Tablet" and category "Mobile Device"
- **AND** the canonical device type is currently unknown
- **WHEN** the device is processed by DIRE
- **THEN** `ocsf_devices.type_id` is set to the OCSF tablet type
- **AND** `ocsf_devices.type` is set to "Tablet"
- **AND** the Armis type/category remain visible in the Armis metadata card

#### Scenario: Inferred type from discovery signals
- **GIVEN** a device discovered via SNMP with sysDescr containing "Cisco IOS Router"
- **WHEN** the device is processed by DIRE
- **THEN** the device SHALL have `type_id = 12` and `type = "Router"`

#### Scenario: Unknown type fallback
- **GIVEN** a device with no type indicators
- **WHEN** the device is processed by DIRE
- **THEN** the device SHALL have `type_id = 0` and `type = "Unknown"`

### Requirement: OCSF Risk and Compliance Fields
The system SHALL store risk and compliance status:
- `risk_level_id` (INTEGER): Normalized risk level (0=Info, 1=Low, 2=Medium, 3=High, 4=Critical, 99=Other)
- `risk_level` (TEXT): Risk level caption
- `risk_score` (INTEGER): Numeric risk score from source system
- `is_managed` (BOOLEAN): Device is managed by MDM/endpoint management
- `is_compliant` (BOOLEAN): Device meets compliance requirements
- `is_trusted` (BOOLEAN): Device is trusted for network access

Device details SHALL render risk score from sources such as Armis as a compact visual indicator when the source scale is known, while preserving the raw numeric value for audit/debugging.

#### Scenario: High-risk device from Armis
- **GIVEN** a device with Armis risk score 85
- **WHEN** the device is processed by DIRE
- **THEN** `risk_score` SHALL be 85
- **AND** `risk_level_id` SHALL be 3 (High) based on score threshold
- **AND** `risk_level` SHALL be "High"

#### Scenario: Armis ten-point risk score is rendered
- **GIVEN** a device with Armis risk score 5 on a 1-10 scale
- **WHEN** an operator opens device details
- **THEN** the Risk and Compliance card shows a visual score treatment
- **AND** the raw score value remains visible

#### Scenario: Managed compliant device
- **GIVEN** a device flagged as managed and compliant in NetBox
- **WHEN** the device is processed by DIRE
- **THEN** `is_managed` SHALL be TRUE
- **AND** `is_compliant` SHALL be TRUE

## ADDED Requirements
### Requirement: Device details integration metadata is source-grouped
The device details UI SHALL group integration and discovery metadata into source-specific cards such as SNMP, Armis, NetBox, UniFi, MikroTik, Proxmox, and Discovery. It SHALL prioritize human-useful fields, render timestamps/durations readably, and avoid redundant cards for data already shown in first-class tables.

#### Scenario: SNMP metadata is grouped
- **GIVEN** a device has SNMP sysName, sysDescr, sysLocation, sysObjectID, and uptime metadata
- **WHEN** an operator opens device details
- **THEN** the metadata area shows an SNMP card with those fields
- **AND** uptime is rendered as a readable duration or timestamp
- **AND** raw debug payloads are hidden unless explicitly requested

#### Scenario: Redundant aliases are omitted
- **GIVEN** a device has IP aliases shown in the dedicated aliases table
- **WHEN** device details renders metadata cards
- **THEN** it does not render a redundant Aliases metadata card with the same IP list

#### Scenario: Source cards are not shown for unrelated data
- **GIVEN** a device is a UniFi router and has no MikroTik-specific enrichment
- **WHEN** device details renders metadata cards
- **THEN** it does not show a MikroTik card just because generic controller names or URLs exist

### Requirement: Device details logs are bounded and empty-state aware
The device details Logs tab SHALL query logs by device identity using a bounded SRQL/log query and SHALL render an immediate empty state when no rows exist. The tab SHALL NOT block indefinitely or surface a LiveView push timeout merely because a device has no associated logs.

#### Scenario: Device has no logs
- **GIVEN** a device has no associated log rows
- **WHEN** an operator opens the Logs tab
- **THEN** the UI shows zero rows and an empty state
- **AND** the LiveView event completes without a timeout toast

#### Scenario: Device has recent logs
- **GIVEN** a device has associated log rows
- **WHEN** an operator opens the Logs tab
- **THEN** the UI shows the bounded recent log rows
- **AND** provides a link to the full logs view with the device query applied

### Requirement: Device availability summary uses recent per-agent observations
The device details Agent Availability summary SHALL reflect the same recent per-agent sweep observations shown in Recent Sweep History. It SHALL identify the canonical availability source and SHALL NOT claim no per-agent availability exists when recent per-agent sweep history is present.

#### Scenario: Recent sweep history exists
- **GIVEN** a device has recent sweep history from `agent-dusk01`
- **WHEN** an operator opens device details
- **THEN** the Agent Availability card shows `agent-dusk01` with recent status and freshness
- **AND** the canonical source label matches the configured or fallback availability source
