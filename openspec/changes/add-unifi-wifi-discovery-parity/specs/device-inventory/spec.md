## ADDED Requirements

### Requirement: Wireless client device tracking
The system SHALL track wireless clients as OCSF device entities with WiFi-specific metadata extensions, maintaining connection history and last-known state.

#### Scenario: Wireless client creates device inventory entry
- **GIVEN** a wireless client discovered via controller API with MAC, IP, and fingerprint data
- **WHEN** the client is processed by DIRE
- **THEN** an OCSF device record SHALL be created with:
  - `uid` generated from client MAC via DIRE identity rules
  - `type_id` mapped from fingerprint data (5=Mobile, 3=Laptop, 7=IoT, etc.)
  - `mac` set to client MAC address
  - `ip` set to client IP address
  - `vendor_name` set from fingerprint or MAC OUI lookup
- **AND** WiFi-specific metadata SHALL be stored: `last_ap_mac`, `last_ssid`, `last_vlan_id`, `last_signal_dbm`, `last_wifi_generation`

#### Scenario: Wireless client updates on reconnection
- **GIVEN** a previously known wireless client that reconnects (possibly to a different AP or SSID)
- **WHEN** the client observation is ingested
- **THEN** the existing device record SHALL be updated with current connection state
- **AND** `last_seen_at` SHALL be refreshed
- **AND** `last_ap_mac`, `last_ssid`, `last_signal_dbm` SHALL reflect the current connection

#### Scenario: Wireless client offline retention
- **GIVEN** a wireless client that has not been observed for longer than the configured offline retention period (default: 30 days)
- **WHEN** the retention cleanup job runs
- **THEN** the device record SHALL be soft-deleted or marked as stale
- **AND** the observation hypertable data SHALL follow its own retention policy (independent of device retention)

### Requirement: Multi-source device fingerprint enrichment
The system SHALL enrich device classification using multiple fingerprint sources in priority order: controller fingerprint database, SNMP system description, MAC OUI vendor lookup.

#### Scenario: Controller fingerprint provides device type
- **GIVEN** a device discovered via UniFi API with fingerprint data indicating "Smart TV"
- **WHEN** the device is processed by DIRE
- **THEN** `type_id` SHALL be set to 7 (IoT) and `type` to "Smart TV"
- **AND** `vendor_name` SHALL be set from the fingerprint data if available

#### Scenario: SNMP sysDescr provides OS information
- **GIVEN** a device discovered via SNMP with sysDescr "Cisco IOS XE Software, Version 17.6.3"
- **AND** no controller fingerprint available
- **WHEN** the device is processed by DIRE
- **THEN** the `os` JSONB SHALL be populated with parsed OS information
- **AND** `type_id` SHALL be inferred from sysDescr patterns (Router=12 for IOS)

#### Scenario: MAC OUI provides vendor when no other source available
- **GIVEN** a device with only a MAC address (no SNMP, no controller fingerprint)
- **WHEN** the device is processed by the fingerprint enrichment pipeline
- **THEN** `vendor_name` SHALL be set from IEEE OUI lookup (e.g., "Apple, Inc." for 00:1B:63:xx:xx:xx)
- **AND** `type_id` SHALL remain 0 (Unknown) unless OUI implies a device category

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
- `last_ap_mac` (TEXT): Last associated AP MAC (wireless clients only)
- `last_ssid` (TEXT): Last connected SSID (wireless clients only)
- `last_wifi_generation` (TEXT): Last observed WiFi generation (wireless clients only)
- `fingerprint_source` (TEXT): Source of device classification (controller, snmp, oui, manual)
- `fingerprint_confidence` (FLOAT): Classification confidence score (0.0-1.0)

#### Scenario: Device with all core fields populated
- **GIVEN** a device discovered via Armis sync with full metadata
- **WHEN** the device is processed by DIRE
- **THEN** all core OCSF fields SHALL be populated from available metadata

#### Scenario: Device with minimal identification
- **GIVEN** a device discovered via network sweep with only IP address
- **WHEN** the device is processed by DIRE
- **THEN** the device SHALL have `uid`, `ip`, and `type_id` (0=Unknown) populated
- **AND** other fields SHALL be NULL until enriched

#### Scenario: Wireless client device with WiFi metadata
- **GIVEN** a wireless client discovered via controller API
- **WHEN** the device is processed by DIRE
- **THEN** the device SHALL have WiFi-specific fields populated: `last_ap_mac`, `last_ssid`, `last_wifi_generation`
- **AND** `fingerprint_source` SHALL indicate the classification source
- **AND** `fingerprint_confidence` SHALL reflect the confidence level of the classification
