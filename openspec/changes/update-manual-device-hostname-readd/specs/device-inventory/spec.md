## MODIFIED Requirements
### Requirement: OCSF Device Schema

The system SHALL store device inventory in a schema aligned with OCSF v1.7.0 Device object, supporting the following core fields:
- `uid` (TEXT, PRIMARY KEY): Unique device identifier (sr: prefixed UUID from DIRE, or deterministic manual identity where applicable)
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

#### Scenario: Manual hostname-only device is re-added after DNS resolution
- **GIVEN** an existing manual device has hostname `serviceradar.cloud` and no primary IP address
- **WHEN** an operator manually adds `serviceradar.cloud` again without entering an IP address
- **THEN** the system SHALL resolve the hostname to an IP address
- **AND** SHALL update the existing device with the resolved IP address
- **AND** SHALL NOT fail the create request solely because a matching hostname-only record already exists

#### Scenario: Soft-deleted manual device is re-added
- **GIVEN** a soft-deleted manual device matches a new manual submission by deterministic manual UID, resolved IP address, or hostname
- **WHEN** an operator adds the same device again
- **THEN** the system SHALL restore the existing device
- **AND** SHALL update it with the resolved IP address and current manual metadata
- **AND** SHALL return the restored device as a successful create/update result

#### Scenario: Manual device save navigates to details
- **GIVEN** an operator successfully adds or re-adds a manual device
- **WHEN** the device is saved
- **THEN** the web UI SHALL navigate directly to the saved device's details page
