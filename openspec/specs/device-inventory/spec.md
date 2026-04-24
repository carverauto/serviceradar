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
- **GIVEN** a device discovered via integration ingestion (non-sweep) with only IP address
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
- **GIVEN** a new device discovered via sync integration ingestion or manual inventory entry (non-sweep)
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
The system SHALL treat `ocsf_devices.network_interfaces` as a non-canonical cache and SHALL NOT depend on it for interface presentation.

#### Scenario: Interface presentation uses SRQL
- **GIVEN** a device with interface observations stored in the time-series table
- **WHEN** the device details UI requests interfaces
- **THEN** the UI SHALL query SRQL `in:interfaces` and NOT rely on `ocsf_devices.network_interfaces`

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
- **GIVEN** a device discovered via manual inventory entry or integration ingestion (non-sweep) with only IP address
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

### Requirement: Device Dashboard Stats Cards

The system SHALL display summary statistics cards above the devices table on the devices dashboard page.

The stats cards section SHALL include:
- Total Devices card: Shows total device count
- Available Devices card: Shows available count with success styling
- Unavailable Devices card: Shows unavailable count with error styling when > 0
- Device Types card: Shows breakdown of device types (top 5)
- Top Vendors card: Shows breakdown by vendor (top 5)

#### Scenario: Stats cards display on page load
- **GIVEN** a user navigates to the devices dashboard
- **WHEN** the page loads
- **THEN** stats cards SHALL be displayed above the devices table
- **AND** cards SHALL show current statistics via SRQL queries

#### Scenario: Stats cards show loading state
- **GIVEN** a user navigates to the devices dashboard
- **WHEN** statistics are being fetched
- **THEN** stats cards SHALL display skeleton placeholders

#### Scenario: Unavailable devices highlighted
- **GIVEN** there are unavailable devices in the inventory
- **WHEN** the stats cards are displayed
- **THEN** the Unavailable Devices card SHALL use error styling (red tone)
- **AND** the count SHALL be prominently displayed

#### Scenario: Stats cards are clickable filters
- **GIVEN** the stats cards are displayed
- **WHEN** a user clicks on the "Unavailable Devices" card
- **THEN** the devices table SHALL filter to show only unavailable devices

#### Scenario: Stats loaded via parallel SRQL queries
- **GIVEN** the devices dashboard is loading
- **WHEN** stats are fetched
- **THEN** multiple SRQL queries SHALL execute in parallel
- **AND** each card SHALL load independently

### Requirement: Interface Observations Time-Series
The system SHALL store interface observations in a single time-series table covering routers and servers.

Interface observations SHALL include at minimum:
- `timestamp` (TIMESTAMPTZ) - observation time
- `device_id` (TEXT) - canonical device UID
- `device_ip` (TEXT) - device IP at observation time
- `if_index` (INTEGER, nullable) - interface index (SNMP ifIndex)
- `if_name` (TEXT, nullable)
- `if_descr` (TEXT, nullable)
- `if_alias` (TEXT, nullable)
- `if_type` (INTEGER, nullable) - numeric interface type identifier
- `if_type_name` (TEXT, nullable) - human-readable type (e.g., ethernetCsmacd)
- `interface_kind` (TEXT, nullable) - classification (physical, virtual, loopback, tunnel, bridge, etc.)
- `mac` (TEXT, nullable)
- `ip_addresses` (TEXT[] or JSON array)
- `speed_bps` (BIGINT, nullable)
- `mtu` (INTEGER, nullable)
- `admin_status` (INTEGER, nullable)
- `oper_status` (INTEGER, nullable)
- `duplex` (TEXT, nullable)
- `metadata` (JSONB, optional)

#### Scenario: Router interface observation
- **GIVEN** a router discovered by SNMP with `ifType`, speed, and MAC
- **WHEN** mapper publishes interface results
- **THEN** the time-series table SHALL store the observation with type fields, MAC, IPs, and speed

#### Scenario: Server interface observation
- **GIVEN** a Linux server with `eth0` and loopback interfaces
- **WHEN** mapper/sysmon publishes interface results
- **THEN** the time-series table SHALL store both interfaces with `interface_kind` set appropriately

### Requirement: Plugin-discovered camera stream enrichment
The system SHALL persist plugin-discovered camera stream metadata as device enrichment tied to canonical device identity.

#### Scenario: Stream metadata attached to canonical device
- **GIVEN** a plugin result containing a valid `device_enrichment.streams` payload and identity hints
- **WHEN** ingestion resolves the canonical device
- **THEN** the stream metadata SHALL be stored as enrichment for that device
- **AND** previous stream observations from the same source SHALL be updated atomically

### Requirement: Stream authentication metadata without secret leakage
The system SHALL store stream authentication requirements and credential reference IDs without storing plaintext secrets in device inventory or enrichment rows.

#### Scenario: Credential reference stored safely
- **GIVEN** a discovered RTSP stream requiring authentication
- **WHEN** enrichment is persisted
- **THEN** the record SHALL include auth mode and credential reference ID only
- **AND** SHALL NOT include raw usernames or passwords in persisted enrichment payloads

### Requirement: Device UI exposure for discovered streams
The device details experience SHALL expose discovered stream metadata (protocol, endpoint, profile, auth mode, freshness) sourced from enrichment records.

#### Scenario: Device details shows discovered AXIS stream entries
- **GIVEN** a device with current stream enrichment data
- **WHEN** a user opens the device details view
- **THEN** the UI SHALL show stream entries and freshness timestamps
- **AND** it SHALL indicate when credentials are required but not configured

### Requirement: Vendor-Scoped Enrichment Rule Matching
The system SHALL only apply vendor-specific device enrichment rules when the input payload contains evidence that is scoped to that vendor.

#### Scenario: Aruba switch does not match Ubiquiti rule
- **GIVEN** a device payload with Aruba fingerprint signals and no Ubiquiti-specific evidence
- **WHEN** enrichment rules are evaluated
- **THEN** Ubiquiti-specific rules SHALL NOT match
- **AND** the resulting classification SHALL NOT set `vendor_name` to `Ubiquiti`

#### Scenario: Ubiquiti classification still works with explicit evidence
- **GIVEN** a device payload that includes Ubiquiti-specific evidence required by a Ubiquiti rule
- **WHEN** enrichment rules are evaluated
- **THEN** the matching Ubiquiti rule SHALL classify the device with `vendor_name=Ubiquiti`
- **AND** vendor/type output SHALL remain consistent with existing Ubiquiti router/switch/AP expectations

### Requirement: Aruba Switch Classification Guardrail
The system SHALL classify Aruba switch fingerprints as Aruba switch devices when Aruba-specific evidence is present and no higher-priority vendor-specific rule applies.

#### Scenario: Aruba switch fingerprint classification
- **GIVEN** a device payload with Aruba switch fingerprint signals
- **WHEN** enrichment rules are evaluated
- **THEN** the winning rule SHALL set `vendor_name=Aruba`
- **AND** the winning rule SHALL set `type=Switch` and `type_id=10`

### Requirement: Protect plugin-discovered camera enrichment
The system SHALL persist UniFi Protect plugin-discovered camera and stream metadata as device enrichment tied to canonical device identity.

#### Scenario: Protect stream metadata attached to canonical device
- **GIVEN** a plugin result containing valid Protect `camera_descriptors` payloads and identity hints
- **WHEN** ingestion resolves the canonical device
- **THEN** the Protect camera and stream metadata SHALL be stored as enrichment for that device
- **AND** previous observations from the same plugin source SHALL be updated atomically

### Requirement: Protect metadata exposed in device views
The device details experience SHALL expose UniFi Protect-discovered camera stream metadata sourced from enrichment records.

#### Scenario: Device details shows discovered Protect stream entries
- **GIVEN** a device with current Protect camera enrichment data
- **WHEN** a user opens the device details view
- **THEN** the UI SHALL show stream entries and freshness timestamps
- **AND** it SHALL indicate when controller-managed credentials or session bootstrap are required

### Requirement: Management Device Relationship

The system SHALL support a `management_device_id` field on devices to indicate that a device is reachable for management operations (e.g., SNMP polling) through another device rather than directly at its own IP address.

#### Scenario: Device created from discovered interface IP has management device set
- **GIVEN** the mapper discovers interfaces on device `sr:parent` at IP `192.168.1.1`
- **AND** an interface on that device has IP `203.0.113.5`
- **WHEN** DIRE creates a new device record for `203.0.113.5`
- **THEN** the new device SHALL have `management_device_id` set to `sr:parent`

#### Scenario: Device without management device retains direct reachability
- **GIVEN** a device with `management_device_id = nil`
- **WHEN** the system determines how to reach the device
- **THEN** the device's own `ip` field SHALL be used

### Requirement: SNMP identity fields are persisted and surfaced
The system SHALL persist SNMP identity metadata (`snmp_name`, `snmp_owner`, `snmp_location`, `snmp_description`) from normalized discovery signals and surface them in device details.

#### Scenario: SNMP identity metadata appears in device details
- **GIVEN** a discovered device with SNMP identity fields present
- **WHEN** a user opens device details
- **THEN** the UI SHALL display the SNMP identity fields with empty values rendered as not available

### Requirement: Inventory fallback uses SNMP fingerprint when enrichment is missing
The inventory UI SHALL use SNMP fingerprint-based fallback display for vendor/type/model when explicit enrichment output is unavailable.

#### Scenario: Type fallback from SNMP signals
- **GIVEN** a device has no explicit enrichment rule match
- **AND** the SNMP fingerprint indicates routing behavior and known vendor/model clues
- **WHEN** the device is rendered in inventory views
- **THEN** the UI SHALL show a fallback vendor/type/model derived from fingerprint mapping
- **AND** indicate that the displayed values are fallback-derived

### Requirement: Device Soft Delete Tombstones
The system SHALL support soft deletion of devices by recording a tombstone timestamp and deletion metadata instead of removing the record immediately.

#### Scenario: Soft delete records tombstone metadata
- **GIVEN** an admin or operator deletes a device
- **WHEN** the delete action is processed
- **THEN** the device SHALL remain in `ocsf_devices`
- **AND** `deleted_at` SHALL be set
- **AND** `deleted_by` SHALL record the deleting actor (if available)
- **AND** `deleted_reason` SHALL be stored when provided

### Requirement: Inventory Filters Exclude Deleted Devices By Default
The system SHALL exclude tombstoned devices from default inventory reads unless explicitly requested.

#### Scenario: Default reads hide deleted devices
- **GIVEN** a device with `deleted_at` set
- **WHEN** a default device list read is executed
- **THEN** the deleted device SHALL NOT be included

#### Scenario: Include deleted devices on demand
- **GIVEN** a device with `deleted_at` set
- **WHEN** a device list read is executed with `include_deleted = true`
- **THEN** the deleted device SHALL be included

### Requirement: Restore Soft-Deleted Devices
The system SHALL support restoring soft-deleted devices by clearing tombstone metadata.

#### Scenario: Restore clears tombstone metadata
- **GIVEN** a device with `deleted_at` set
- **WHEN** an admin or operator restores the device
- **THEN** `deleted_at` SHALL be cleared
- **AND** `deleted_by` and `deleted_reason` SHALL be cleared
- **AND** the device SHALL appear in default inventory reads

#### Scenario: Discovery restores a deleted device
- **GIVEN** a device with `deleted_at` set
- **WHEN** a sweep or integration discovery result matches the device identity
- **THEN** the device SHALL be restored automatically
- **AND** availability/last_seen metadata SHALL be updated from the discovery result

### Requirement: Device Deletion Authorization
Only admin and operator roles SHALL be permitted to delete devices.

#### Scenario: Viewer cannot delete device
- **GIVEN** a viewer attempts to delete a device
- **WHEN** the delete action is processed
- **THEN** the operation SHALL be rejected

### Requirement: Bulk Device Deletion
The system SHALL support bulk soft deletion for a list of device IDs.

#### Scenario: Bulk delete tombstones multiple devices
- **GIVEN** an admin selects multiple devices
- **WHEN** they perform a bulk delete
- **THEN** each selected device SHALL be soft deleted with tombstone metadata

### Requirement: Rule-Driven Vendor and Type Enrichment
The system SHALL derive device `vendor_name`, `model`, `type`, and `type_id` through configurable enrichment rules that evaluate SNMP and mapper metadata.

#### Scenario: Ubiquiti router disambiguation using sysDescr/sysName
- **GIVEN** a device with ambiguous `sys_object_id` but `sys_descr` or `sys_name` indicating `UDM`
- **WHEN** enrichment rules are applied
- **THEN** `vendor_name` SHALL be set to `Ubiquiti`
- **AND** `type`/`type_id` SHALL be set to `Router`/`12`

#### Scenario: Ubiquiti switch disambiguation using sysName
- **GIVEN** a device with `sys_object_id` shared across platforms and `sys_name` containing `USW`
- **WHEN** enrichment rules are applied
- **THEN** `vendor_name` SHALL be set to `Ubiquiti`
- **AND** `type`/`type_id` SHALL be set to `Switch`/`10`

#### Scenario: Ubiquiti AP classification using sysDescr/sysName
- **GIVEN** a device with `sys_descr` or `sys_name` containing `U6` or `UAP`
- **WHEN** enrichment rules are applied
- **THEN** `vendor_name` SHALL be set to `Ubiquiti`
- **AND** `type` SHALL be set to an AP classification value

### Requirement: Classification Provenance Visibility in Inventory
The system SHALL store and expose enrichment provenance fields for each device classification decision.

#### Scenario: Provenance fields present after enrichment
- **WHEN** a rule classifies a device
- **THEN** `ocsf_devices.metadata` SHALL contain rule provenance fields
- **AND** API/UI reads of device inventory SHALL expose those provenance values

#### Scenario: Classification updated by higher-priority rule
- **GIVEN** an existing classified device
- **WHEN** a higher-priority matching rule is introduced and ingestion reprocesses the device
- **THEN** classification fields SHALL be updated to the new decision
- **AND** provenance SHALL reference the new winning rule

### Requirement: Camera stream inventory uses normalized platform tables
The system SHALL store camera source identifiers and stream profile metadata in dedicated `platform` schema tables linked to canonical device identity rather than relying only on opaque metadata fields in `ocsf_devices`.

#### Scenario: Protect plugin discovers a camera and stream profiles
- **GIVEN** camera discovery identifies a canonical device and one or more vendor stream profiles
- **WHEN** the discovery payload is ingested
- **THEN** the canonical device SHALL remain represented in `ocsf_devices`
- **AND** camera-specific source and stream profile records SHALL be created or updated in dedicated related tables

### Requirement: Camera inventory tracks edge affinity and freshness
The camera inventory model SHALL track which edge agent or gateway can originate a camera stream session and SHALL retain freshness metadata for discovered camera profiles.

#### Scenario: Camera profile becomes stale
- **GIVEN** a camera stream profile was last observed by discovery at an earlier timestamp
- **WHEN** that profile is no longer refreshed within the configured freshness window
- **THEN** the system SHALL mark the profile stale
- **AND** viewer workflows SHALL be able to surface that state before attempting live playback

