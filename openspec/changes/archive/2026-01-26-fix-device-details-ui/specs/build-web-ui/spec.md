## ADDED Requirements

### Requirement: Device Detail Shows IP Aliases
The web-ng device detail page SHALL display IP alias records for the device, including alias state and last-seen metadata.

#### Scenario: Device detail displays alias table
- **GIVEN** a device with IP aliases recorded by DIRE
- **WHEN** an admin views the device detail page
- **THEN** the page SHALL list alias IPs with state, last seen time, and sighting count

#### Scenario: Hide stale aliases by default
- **GIVEN** a device with confirmed and stale alias records
- **WHEN** the device detail page loads
- **THEN** stale or archived aliases SHALL be hidden by default
- **AND** the user may toggle to show them
