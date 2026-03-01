## MODIFIED Requirements
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
