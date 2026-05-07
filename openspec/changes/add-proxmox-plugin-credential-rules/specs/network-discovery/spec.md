## ADDED Requirements

### Requirement: Proxmox candidates are identified from existing discovery evidence
The system SHALL identify Proxmox PVE candidate devices from existing mapper, sweep, SNMP, service, and inventory evidence before the Proxmox plugin runs.

#### Scenario: Candidate selected by SRQL rule
- **GIVEN** discovery has found devices with PVE API port evidence, Proxmox fingerprints, tags, or operator labels
- **WHEN** an admin creates a credential rule or plugin policy using SRQL
- **THEN** the query SHALL be able to target those candidate devices without manually listing each Proxmox host in plugin configuration

### Requirement: Proxmox discovery converges with mapper topology semantics
The Proxmox plugin SHALL preserve the hosted virtualization semantics already used by mapper Proxmox discovery.

#### Scenario: Plugin and mapper use compatible identities
- **GIVEN** mapper Proxmox discovery and the Proxmox plugin observe the same PVE node and VMID
- **WHEN** ingestion processes both sources
- **THEN** they SHALL reconcile to the same canonical device identities where sufficient identity hints match
- **AND** hosted topology edges SHALL not be duplicated by source-specific identifier drift

### Requirement: Proxmox plugin assignments are discovery-driven
The system SHALL derive Proxmox plugin assignments from discovered devices, credential rules, and agent reachability rather than static plugin host lists.

#### Scenario: New PVE host is automatically eligible
- **GIVEN** a new PVE host appears in inventory and matches an enabled Proxmox credential rule
- **WHEN** plugin target reconciliation runs
- **THEN** the matching edge agent SHALL receive a Proxmox plugin assignment for that host
- **AND** no operator SHALL need to add the host directly to the plugin config

#### Scenario: Device leaves target scope
- **GIVEN** a device no longer matches the Proxmox credential rule target query
- **WHEN** plugin target reconciliation runs
- **THEN** the corresponding Proxmox plugin assignment SHALL be removed or disabled
