## ADDED Requirements
### Requirement: Private network location anchors
The system SHALL allow administrators to assign optional physical map coordinates to enabled NetFlow local CIDR ranges.

#### Scenario: Admin anchors a private CIDR
- **GIVEN** an authenticated administrator can manage NetFlow settings
- **WHEN** the administrator saves `10.10.0.0/16` with latitude, longitude, and a location label
- **THEN** the system persists the anchor on the local CIDR configuration
- **AND** subsequent dashboard NetFlow map payloads may use that anchor for matching private endpoints

### Requirement: Most-specific anchor resolution
When multiple enabled local CIDR anchors match a NetFlow endpoint, the system SHALL use the most-specific matching CIDR.

#### Scenario: Endpoint matches nested anchors
- **GIVEN** `10.0.0.0/8` and `10.10.0.0/16` both have configured anchors
- **WHEN** a flow endpoint is `10.10.5.20`
- **THEN** the dashboard map payload uses the `10.10.0.0/16` anchor

### Requirement: Honest geographic NetFlow rendering
The dashboard NetFlow map SHALL only render geographic arcs when both endpoints have valid coordinates from GeoIP enrichment or configured private-network anchors.

#### Scenario: Flow endpoint has no location
- **GIVEN** a recent NetFlow conversation includes an unanchored private endpoint
- **AND** the endpoint has no GeoIP cache coordinates
- **WHEN** the dashboard renders the NetFlow map
- **THEN** the system does not draw a fabricated geographic arc for that conversation
- **AND** the map empty state explains that GeoIP enrichment or private-network anchors are required
