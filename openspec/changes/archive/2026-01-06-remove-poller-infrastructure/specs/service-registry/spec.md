## ADDED Requirements
### Requirement: Gateway records SHALL persist in a dedicated gateways table
Gateway persistence SHALL use a dedicated `gateways` table that is not shared with poller records.

#### Scenario: Gateway persistence does not collide with poller data
- **GIVEN** a deployment that previously stored gateways and pollers together
- **WHEN** the gateway persistence change is applied
- **THEN** gateway records write to the `gateways` table
- **AND** poller data (if present) remains isolated from gateway persistence
