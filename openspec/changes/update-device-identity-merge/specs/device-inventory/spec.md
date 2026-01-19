## ADDED Requirements

### Requirement: Network Interfaces Stored in Inventory
The system SHALL store discovered interfaces directly in `ocsf_devices.network_interfaces` and SHALL NOT rely on `platform.discovered_interfaces` for interface presentation.

#### Scenario: Interface publish updates device record
- **GIVEN** a mapper discovery cycle that reports interfaces for a device
- **WHEN** the interfaces are published
- **THEN** `ocsf_devices.network_interfaces` SHALL include entries for those interfaces
- **AND** each entry SHALL include interface name, MAC, and IP address information when available
