## ADDED Requirements
### Requirement: Proxmox guest network identity
The system SHALL persist Proxmox guest network interfaces and use MAC/IP identity hints to link virtualized guests to canonical inventory devices.

#### Scenario: Link guest by MAC address
- **GIVEN** a Proxmox guest exposes a NIC MAC address through config or guest-agent data
- **AND** an existing inventory device has the same MAC address
- **WHEN** Proxmox enrichment is ingested
- **THEN** the virtualization guest SHALL link to that canonical device
- **AND** the guest NIC SHALL be persisted with MAC address, source, and observed timestamp

#### Scenario: Link guest by IP address
- **GIVEN** a Proxmox guest exposes IP addresses through LXC config or QEMU guest-agent data
- **AND** no MAC match is available
- **WHEN** Proxmox enrichment is ingested
- **THEN** the system SHALL use those IP addresses as identity hints to link the guest to an existing canonical device when confidence is sufficient
- **AND** the structured guest NIC record SHALL retain the IP evidence source
