## ADDED Requirements

### Requirement: RouterOS API inventory enrichment
The system SHALL use MikroTik RouterOS API discovery metadata to enrich canonical device inventory when RouterOS signals provide stronger identity or hardware detail than existing placeholders.

#### Scenario: RouterOS API populates vendor and model
- **GIVEN** a canonical device discovered from a MikroTik RouterOS source
- **WHEN** RouterOS API data includes board or product metadata
- **THEN** the device inventory record SHALL set `vendor_name` to `MikroTik`
- **AND** populate `model` from the strongest available RouterOS model/board identifier
- **AND** retain existing stronger user-managed values if they already exist

#### Scenario: RouterOS API populates OS and hardware metadata
- **GIVEN** a RouterOS discovery result with operating system version, serial number, and architecture data
- **WHEN** the device is reconciled into inventory
- **THEN** the `os` object SHALL include RouterOS name/version details when available
- **AND** the `hw_info` object SHALL include serial number and architecture fields when available

#### Scenario: RouterOS API metadata complements existing SNMP enrichment
- **GIVEN** a device already classified as MikroTik from SNMP enrichment rules
- **WHEN** RouterOS API discovery later provides more specific model or version data
- **THEN** the canonical device record SHALL be updated with the richer RouterOS metadata
- **AND** the device SHALL preserve its existing canonical identity rather than creating a duplicate record
