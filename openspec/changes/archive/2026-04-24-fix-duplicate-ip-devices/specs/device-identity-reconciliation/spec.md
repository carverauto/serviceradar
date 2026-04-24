## ADDED Requirements
### Requirement: Partition-Scoped IP Uniqueness for IP-only Updates
The system MUST treat (partition, primary IP) as a uniqueness key for IP-only device updates, and MUST resolve IP-only updates to an existing canonical device in the same partition when the primary IP matches.

#### Scenario: IP-only update reuses existing device
- **GIVEN** a device in partition `default` with primary IP `10.0.0.5`
- **WHEN** an IP-only update arrives for `10.0.0.5` in partition `default`
- **THEN** DIRE SHALL resolve the update to the existing canonical device ID
- **AND** MUST NOT create a new device record for the same partition + IP

#### Scenario: Duplicate primary IPs are merged by reconciliation
- **GIVEN** two device IDs in the same partition share the same primary IP `10.0.0.5`
- **WHEN** the reconciliation job runs
- **THEN** the non-canonical device SHALL be merged into the canonical device
- **AND** inventory-linked records SHALL be reassigned to the canonical device ID
