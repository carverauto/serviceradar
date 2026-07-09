## ADDED Requirements
### Requirement: Armis Attachment Metadata Preservation
The Armis sync integration SHALL preserve selected attachment evidence fields from Armis device or asset payloads in device metadata using stable `armis_*` keys.

#### Scenario: Armis access switch fields are preserved
- **GIVEN** an Armis payload includes an access switch value such as `nsfocs-idfer1-asw001:2/20`
- **WHEN** the payload is mapped into a ServiceRadar device update
- **THEN** the update metadata SHALL include the value under a stable key such as `armis_access_switch`

#### Scenario: Armis VLAN and connection metadata are preserved
- **GIVEN** an Armis payload includes VLAN or VLAN array fields, connection type, and DHCP lease type fields
- **WHEN** the payload is mapped into a ServiceRadar device update
- **THEN** the update metadata SHALL include normalized keys such as `armis_vlan`, `armis_vlans`, `armis_connection_type`, and `armis_dhcp_lease_type` when present

#### Scenario: Configured Armis asset fields enrich v1 sync results
- **GIVEN** an Armis source is configured with `asset_fields`
- **AND** the current v1 AQL page includes Armis asset IDs
- **WHEN** the sync driver fetches the page
- **THEN** the driver SHALL request the configured fields from Armis v3 by asset ID
- **AND** returned field values SHALL be preserved in device metadata using stable `armis_*` keys

#### Scenario: Endpoint network interface inventory is not treated as attachment evidence
- **GIVEN** an Armis payload includes endpoint NIC inventory fields
- **WHEN** the payload is mapped into device metadata
- **THEN** NIC inventory MAY be preserved separately
- **AND** NIC inventory SHALL NOT be used as a substitute for access switch or switchport attachment evidence
