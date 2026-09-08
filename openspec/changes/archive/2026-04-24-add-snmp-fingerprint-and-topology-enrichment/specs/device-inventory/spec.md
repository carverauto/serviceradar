## ADDED Requirements
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
