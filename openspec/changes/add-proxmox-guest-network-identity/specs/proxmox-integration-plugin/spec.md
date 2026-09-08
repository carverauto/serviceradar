## MODIFIED Requirements
### Requirement: Proxmox node and guest discovery
The Proxmox plugin SHALL discover PVE nodes, QEMU guests, and LXC guests and emit typed device discovery payloads with network identity hints when available.

#### Scenario: Discover node and guests
- **GIVEN** a reachable Proxmox VE API with at least one node and one guest
- **WHEN** the plugin runs with authorized credentials
- **THEN** the plugin SHALL emit a `serviceradar.device_discovery.v1` payload containing the PVE node and guest devices
- **AND** the payload SHALL include stable identity hints for cluster, node, VMID, guest type, hostname/name, IP/MAC when available, and provider source

#### Scenario: Collect guest-agent network interfaces
- **GIVEN** a running QEMU guest has the Proxmox guest agent enabled
- **WHEN** the Proxmox plugin enriches the guest
- **THEN** it SHALL query the guest-agent network interface endpoint
- **AND** include interface names, MAC addresses, and non-loopback IP addresses in the plugin result and discovery hints
