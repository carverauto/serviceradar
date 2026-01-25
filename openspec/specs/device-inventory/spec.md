# device-inventory Specification

## Purpose
TBD - created by archiving change add-ocsf-device-inventory-schema. Update Purpose after archive.
## Requirements
### Requirement: OCSF Device Schema

The system SHALL store device inventory in a schema aligned with OCSF v1.7.0 Device object, supporting the following core fields:
- `uid` (TEXT, PRIMARY KEY): Unique device identifier (sr: prefixed UUID from DIRE)
- `type_id` (INTEGER, NOT NULL): OCSF device type enum (0-15, 99)
- `type` (TEXT): Human-readable device type name
- `name` (TEXT): Administrator-assigned device name
- `hostname` (TEXT): Device hostname
- `ip` (TEXT): Primary IP address
- `mac` (TEXT): Primary MAC address
- `vendor_name` (TEXT): Device manufacturer
- `model` (TEXT): Device model identifier
- `domain` (TEXT): Network domain
- `zone` (TEXT): Network zone or LAN segment

#### Scenario: Device with all core fields populated
- **GIVEN** a device discovered via Armis sync with full metadata
- **WHEN** the device is processed by DIRE
- **THEN** all core OCSF fields SHALL be populated from available metadata

#### Scenario: Device with minimal identification
- **GIVEN** a device discovered via network sweep with only IP address
- **WHEN** the device is processed by DIRE
- **THEN** the device SHALL have `uid`, `ip`, and `type_id` (0=Unknown) populated
- **AND** other fields SHALL be NULL until enriched

---

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

#### Scenario: Explicit type from integration
- **GIVEN** a device with category "Firewall" from Armis
- **WHEN** the device is processed by DIRE
- **THEN** the device SHALL have `type_id = 9` and `type = "Firewall"`

#### Scenario: Inferred type from discovery signals
- **GIVEN** a device discovered via SNMP with sysDescr containing "Cisco IOS Router"
- **WHEN** the device is processed by DIRE
- **THEN** the device SHALL have `type_id = 12` and `type = "Router"`

#### Scenario: Unknown type fallback
- **GIVEN** a device with no type indicators
- **WHEN** the device is processed by DIRE
- **THEN** the device SHALL have `type_id = 0` and `type = "Unknown"`

---

### Requirement: OCSF Operating System Object

The system SHALL store operating system information as a JSONB `os` column containing:
- `name` (TEXT): OS name (e.g., "Windows 11", "Ubuntu")
- `type` (TEXT): OS family (e.g., "Windows", "Linux", "macOS")
- `type_id` (INTEGER): OCSF OS type enum
- `version` (TEXT): OS version string
- `build` (TEXT): OS build number
- `edition` (TEXT): OS edition (e.g., "Enterprise", "Pro")
- `kernel_release` (TEXT): Kernel version for Linux/Unix
- `cpu_bits` (INTEGER): Architecture bits (32 or 64)
- `sp_name` (TEXT): Service pack name
- `sp_ver` (TEXT): Service pack version
- `lang` (TEXT): OS language

#### Scenario: Windows device with full OS info
- **GIVEN** a device with Armis OS metadata "Windows 11 Enterprise 22H2"
- **WHEN** the device is processed by DIRE
- **THEN** the `os` JSONB SHALL contain `{"name": "Windows 11", "type": "Windows", "edition": "Enterprise", "version": "22H2"}`

#### Scenario: Linux device with kernel info
- **GIVEN** a device with SNMP sysDescr "Linux 5.15.0-generic"
- **WHEN** the device is processed by DIRE
- **THEN** the `os` JSONB SHALL contain `{"type": "Linux", "kernel_release": "5.15.0-generic"}`

---

### Requirement: OCSF Hardware Info Object

The system SHALL store hardware information as a JSONB `hw_info` column containing:
- `cpu_architecture` (TEXT): CPU architecture (e.g., "x86_64", "arm64")
- `cpu_bits` (INTEGER): CPU bits (32 or 64)
- `cpu_cores` (INTEGER): Number of CPU cores
- `cpu_count` (INTEGER): Number of physical CPUs
- `cpu_speed_mhz` (DOUBLE): CPU speed in MHz
- `cpu_type` (TEXT): CPU model name
- `ram_size` (BIGINT): Total RAM in bytes
- `serial_number` (TEXT): Device serial number
- `chassis` (TEXT): Chassis type
- `bios_manufacturer` (TEXT): BIOS manufacturer
- `bios_ver` (TEXT): BIOS version
- `bios_date` (TEXT): BIOS release date
- `uuid` (TEXT): Hardware UUID

#### Scenario: Server with hardware inventory
- **GIVEN** a server device with hardware info from sysmon agent
- **WHEN** the device is processed by DIRE
- **THEN** the `hw_info` JSONB SHALL contain CPU, RAM, and serial number fields

---

### Requirement: OCSF Temporal Fields

The system SHALL track device lifecycle timestamps:
- `first_seen_time` (TIMESTAMPTZ): When device was first discovered
- `last_seen_time` (TIMESTAMPTZ): When device was last observed
- `created_time` (TIMESTAMPTZ): When device record was created
- `modified_time` (TIMESTAMPTZ): When device record was last modified

#### Scenario: New device discovery
- **GIVEN** a new device discovered via network sweep
- **WHEN** the device is processed by DIRE
- **THEN** `first_seen_time`, `created_time`, and `last_seen_time` SHALL be set to the discovery timestamp
- **AND** `modified_time` SHALL be set to the current timestamp

#### Scenario: Device re-sighting
- **GIVEN** an existing device sighted again via network sweep
- **WHEN** the device update is processed by DIRE
- **THEN** `last_seen_time` and `modified_time` SHALL be updated
- **AND** `first_seen_time` and `created_time` SHALL remain unchanged

---

### Requirement: OCSF Risk and Compliance Fields

The system SHALL store risk and compliance status:
- `risk_level_id` (INTEGER): Normalized risk level (0=Info, 1=Low, 2=Medium, 3=High, 4=Critical, 99=Other)
- `risk_level` (TEXT): Risk level caption
- `risk_score` (INTEGER): Numeric risk score from source system
- `is_managed` (BOOLEAN): Device is managed by MDM/endpoint management
- `is_compliant` (BOOLEAN): Device meets compliance requirements
- `is_trusted` (BOOLEAN): Device is trusted for network access

#### Scenario: High-risk device from Armis
- **GIVEN** a device with Armis risk score 85
- **WHEN** the device is processed by DIRE
- **THEN** `risk_score` SHALL be 85
- **AND** `risk_level_id` SHALL be 3 (High) based on score threshold
- **AND** `risk_level` SHALL be "High"

#### Scenario: Managed compliant device
- **GIVEN** a device flagged as managed and compliant in NetBox
- **WHEN** the device is processed by DIRE
- **THEN** `is_managed` SHALL be TRUE
- **AND** `is_compliant` SHALL be TRUE

---

### Requirement: OCSF Network Interfaces Array

The system SHALL store network interfaces as a JSONB `network_interfaces` array where each element contains:
- `mac` (TEXT): Interface MAC address
- `ip` (TEXT): Interface IP address
- `hostname` (TEXT): Interface hostname
- `name` (TEXT): Interface name (e.g., "eth0", "ens192")
- `uid` (TEXT): Interface unique identifier
- `type` (TEXT): Interface type name
- `type_id` (INTEGER): OCSF interface type enum

#### Scenario: Multi-homed server
- **GIVEN** a server with two network interfaces discovered via SNMP
- **WHEN** the device is processed by DIRE
- **THEN** `network_interfaces` SHALL contain an array with two interface objects
- **AND** each interface SHALL have `mac`, `ip`, and `name` populated

---

### Requirement: OCSF Device Export

The system SHALL provide an API endpoint to export device inventory in OCSF-compliant JSON format.

#### Scenario: Export all devices
- **GIVEN** a user with appropriate permissions
- **WHEN** they request `GET /api/devices/ocsf/export`
- **THEN** the response SHALL be a JSON array of OCSF Device objects
- **AND** each object SHALL conform to OCSF v1.7.0 Device schema

#### Scenario: Export filtered by type
- **GIVEN** a user requesting only router devices
- **WHEN** they request `GET /api/devices/ocsf/export?type_id=12`
- **THEN** the response SHALL contain only devices with `type_id = 12`

#### Scenario: Export with time range
- **GIVEN** a user requesting devices seen in the last 24 hours
- **WHEN** they request `GET /api/devices/ocsf/export?last_seen_after=<timestamp>`
- **THEN** the response SHALL contain only devices with `last_seen_time` >= the specified timestamp

---

### Requirement: DIRE Identity Resolution Integration

The system SHALL use DIRE's existing `device_identifiers` table for identity resolution, with `ocsf_devices.uid` set to the canonical device ID that DIRE resolves.

#### Scenario: Device with Armis ID
- **GIVEN** a device with Armis device ID "armis-12345"
- **WHEN** the device is processed by DIRE
- **THEN** DIRE SHALL resolve a deterministic `uid` from the Armis ID via `device_identifiers`
- **AND** the `ocsf_devices` record SHALL be created/updated with that `uid`

#### Scenario: Device identified by MAC
- **GIVEN** a device identified only by MAC address "AA:BB:CC:DD:EE:FF"
- **WHEN** the device is processed by DIRE
- **THEN** DIRE SHALL resolve a deterministic `uid` from the MAC via `device_identifiers`
- **AND** the `ocsf_devices` record SHALL be created/updated with that `uid`

#### Scenario: New device without strong identifier
- **GIVEN** a device discovered via network sweep with only IP address
- **WHEN** the device is processed by DIRE
- **THEN** DIRE SHALL generate a new `uid` and register it in `device_identifiers`
- **AND** the `ocsf_devices` record SHALL be created with that `uid` and `type_id = 0` (Unknown)

### Requirement: Sync ingestion transitions emit OCSF events
The system SHALL record OCSF Event Log Activity entries when an integration source sync ingestion starts and finishes.

#### Scenario: Sync ingestion start and finish events
- **GIVEN** a sync ingestion run for an integration source
- **WHEN** the ingestion transitions to running and then completes
- **THEN** the tenant `ocsf_events` table SHALL include start and finish entries
- **AND** the events SHALL include the integration source ID and result

### Requirement: Device Tags Map

The system SHALL store user-defined device tags in `ocsf_devices.tags` as a JSONB map of key/value pairs.

#### Scenario: Persist tag keys and values
- **GIVEN** a user applies tags `env=prod` and `critical` to a device
- **WHEN** the device record is saved
- **THEN** `ocsf_devices.tags` SHALL include `env` with value `"prod"`
- **AND** tags without values SHALL be stored with an empty string value

---

### Requirement: Bulk Tag Application

The system SHALL allow users to apply tags to multiple devices via bulk edit.

#### Scenario: Bulk apply tags to selected devices
- **GIVEN** a user selects multiple devices in the inventory list
- **WHEN** they use the bulk editor to add tags
- **THEN** the selected devices SHALL receive those tags

---

### Requirement: Tags Exposed for Sweep Targeting

The system SHALL expose device tags for sweep group targeting and query evaluation.

#### Scenario: Target devices by tag in sweep group
- **GIVEN** a sweep group targeting rule `tags.env = 'prod'`
- **WHEN** the group is compiled for a sweep config
- **THEN** only devices with `ocsf_devices.tags.env = 'prod'` SHALL be included

### Requirement: Conflict-Safe Sync Upserts
The system SHALL upsert device inventory records for sync updates so concurrent batches do not drop updates when devices already exist.

#### Scenario: Duplicate device across concurrent batches
- **WHEN** two sync batches include updates for the same device UID
- **THEN** device ingestion SHALL complete without duplicate key errors
- **AND** the device record SHALL be updated using the latest ingested fields

### Requirement: Discovery Source Propagation

The system SHALL populate the `discovery_sources` field in `ocsf_devices` with the integration source type(s) that discovered each device.

#### Scenario: Device discovered by Armis integration
- **GIVEN** a device update received from the Armis sync integration with `source: "armis"`
- **WHEN** the device is processed by the SyncIngestor
- **THEN** the `ocsf_devices` record SHALL have `discovery_sources` containing `["armis"]`

#### Scenario: Device discovered by NetBox integration
- **GIVEN** a device update received from the NetBox sync integration with `source: "netbox"`
- **WHEN** the device is processed by the SyncIngestor
- **THEN** the `ocsf_devices` record SHALL have `discovery_sources` containing `["netbox"]`

#### Scenario: Device discovered by multiple sources
- **GIVEN** a device first discovered by Armis with `source: "armis"`
- **AND** the same device is later discovered by NetBox with `source: "netbox"`
- **WHEN** both updates are processed by the SyncIngestor
- **THEN** the `ocsf_devices` record SHALL have `discovery_sources` containing `["armis", "netbox"]`
- **AND** the array SHALL contain no duplicate entries

#### Scenario: Device update with missing source field
- **GIVEN** a device update received without a `source` field
- **WHEN** the device is processed by the SyncIngestor
- **THEN** the `ocsf_devices` record SHALL have `discovery_sources` containing `["unknown"]`

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

### Requirement: Device-level SNMP credential overrides
The system SHALL allow per-device SNMP credential overrides that supersede profile credentials during discovery and polling.

#### Scenario: Persist per-device overrides
- **GIVEN** an admin saves SNMP credentials on a device
- **WHEN** the device is updated
- **THEN** the credentials SHALL be stored encrypted and associated with the device

#### Scenario: Override applied to polling
- **GIVEN** a device with a stored SNMP credential override
- **WHEN** SNMP polling config is generated
- **THEN** the override SHALL be used for that device

