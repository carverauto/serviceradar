## ADDED Requirements

### Requirement: Proxmox inventory enrichment
The system SHALL persist Proxmox plugin-discovered node and guest metadata as enrichment tied to canonical device identity.

#### Scenario: PVE node enrichment is stored
- **GIVEN** a Proxmox plugin result identifies a PVE node
- **WHEN** enrichment ingestion resolves the canonical device
- **THEN** the device SHALL be enriched with vendor `Proxmox`, role `hypervisor`, OS `Proxmox VE`, cluster metadata, node name, version when available, and freshness timestamp
- **AND** raw credentials SHALL NOT be persisted in inventory or enrichment rows

#### Scenario: QEMU and LXC guests are stored
- **GIVEN** a Proxmox plugin result identifies QEMU and LXC guests
- **WHEN** enrichment ingestion resolves canonical identities
- **THEN** guest devices SHALL be represented as virtual devices
- **AND** metadata SHALL include Proxmox cluster, host node, VMID, guest type, status, template flag, and source provenance

### Requirement: Proxmox hosted topology enrichment
The system SHALL represent Proxmox host-to-guest relationships as hosted virtualization topology, not physical network adjacency.

#### Scenario: Guest hosted on PVE node
- **GIVEN** the Proxmox plugin reports guest `101` running on node `pve-a`
- **WHEN** topology enrichment is ingested
- **THEN** the system SHALL create or update a hosted virtualization relation between the canonical guest and node
- **AND** it SHALL NOT create a physical `CONNECTS_TO` edge solely from this Proxmox relationship

### Requirement: Proxmox enrichment freshness
The system SHALL track freshness and source provenance for Proxmox enrichment.

#### Scenario: Proxmox enrichment becomes stale
- **GIVEN** a Proxmox guest was last enriched by the plugin at an earlier timestamp
- **WHEN** the configured freshness window elapses without a new observation
- **THEN** the enrichment SHALL be marked stale
- **AND** inventory reads SHALL distinguish stale Proxmox metadata from current observations

### Requirement: Proxmox fields exposed for SRQL-backed inventory views
The system SHALL expose Proxmox enrichment fields to SRQL-backed inventory views.

#### Scenario: Filter Proxmox guests by host node
- **GIVEN** Proxmox enrichment exists for guest devices
- **WHEN** a user runs an SRQL query for Proxmox guests on a host node
- **THEN** the query SHALL be able to filter by provider, cluster, node, VMID, guest type, status, and freshness

### Requirement: Proxmox console capability exposure
The system SHALL expose console capability metadata for Proxmox-enriched devices without exposing credentials.

#### Scenario: Device details shows console availability
- **GIVEN** a PVE host or guest has matching console credential rules and an eligible edge agent
- **WHEN** an authorized user opens device details
- **THEN** the UI SHALL indicate which console modes are available
- **AND** it SHALL NOT expose SSH keys, Proxmox tickets, passwords, or API tokens
