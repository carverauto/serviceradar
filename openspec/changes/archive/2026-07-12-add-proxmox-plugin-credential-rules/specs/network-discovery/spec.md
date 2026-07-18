## ADDED Requirements

### Requirement: Proxmox candidates are identified from existing discovery evidence
The system SHALL identify Proxmox PVE candidate devices from existing mapper, sweep, SNMP, service, and inventory evidence before the Proxmox plugin runs.

#### Scenario: Candidate selected by SRQL rule
- **GIVEN** discovery has found devices with PVE API port evidence, Proxmox fingerprints, tags, or operator labels
- **WHEN** an admin creates a credential rule or plugin policy using SRQL
- **THEN** the query SHALL be able to target those candidate devices without manually listing each Proxmox host in plugin configuration

#### Scenario: Candidate fingerprinted without credentials
- **GIVEN** a discovered device exposes HTTPS on the Proxmox API port or an operator SRQL query selects it as a possible PVE
- **WHEN** the discovery pipeline probes the device as a Proxmox candidate
- **THEN** the probe SHALL use only unauthenticated, read-only fingerprint checks such as API availability, TLS/service metadata, and safe version endpoint behavior
- **AND** the probe SHALL NOT request, resolve, or transmit a Proxmox API token
- **AND** the resulting evidence SHALL be stored as candidate evidence that can be used by later SRQL credential-rule targeting

#### Scenario: Imported inventory tags define candidate scope
- **GIVEN** devices imported from NetBox, Armis, or another inventory source include tags or custom fields that identify Proxmox hosts
- **WHEN** an admin writes a Proxmox credential rule target query using those fields
- **THEN** the control plane SHALL evaluate that SRQL query server-side and produce concrete candidate devices for eligible agents
- **AND** the Proxmox plugin SHALL NOT require those hosts to be hard-coded in plugin configuration

### Requirement: Proxmox discovery converges with mapper topology semantics
The Proxmox plugin SHALL preserve the hosted virtualization semantics already used by mapper Proxmox discovery.

#### Scenario: Plugin and mapper use compatible identities
- **GIVEN** mapper Proxmox discovery and the Proxmox plugin observe the same PVE node and VMID
- **WHEN** ingestion processes both sources
- **THEN** they SHALL reconcile to the same canonical device identities where sufficient identity hints match
- **AND** hosted topology edges SHALL not be duplicated by source-specific identifier drift

### Requirement: Proxmox plugin assignments are discovery-driven
The system SHALL derive Proxmox plugin assignments from discovered devices, credential rules, and agent reachability rather than static plugin host lists.

#### Scenario: Credential trials are SRQL-scoped by default
- **GIVEN** a Proxmox credential rule has auto-discovery disabled
- **AND** a device responds like a Proxmox API but does not match the rule SRQL target query
- **WHEN** plugin target reconciliation runs
- **THEN** the device SHALL NOT receive a credential broker grant
- **AND** the agent SHALL NOT try the rule credential against that device

#### Scenario: Admin opts into auto-discovery credential trials
- **GIVEN** an admin enables auto-discovery for a Proxmox credential rule in settings
- **AND** the rule is scoped to a specific agent, gateway, or partition
- **WHEN** discovered Proxmox candidate evidence is reconciled for that scope
- **THEN** the control plane MAY produce broker grants for matching candidates inside that scope
- **AND** the UI SHALL make the rule visibly distinguishable from SRQL-only scoped rules

#### Scenario: New PVE host is automatically eligible
- **GIVEN** a new PVE host appears in inventory and matches an enabled Proxmox credential rule SRQL query
- **WHEN** plugin target reconciliation runs
- **THEN** the matching edge agent SHALL receive a Proxmox plugin assignment for that host
- **AND** no operator SHALL need to add the host directly to the plugin config

#### Scenario: Device leaves target scope
- **GIVEN** a device no longer matches the Proxmox credential rule target query
- **WHEN** plugin target reconciliation runs
- **THEN** the corresponding Proxmox plugin assignment SHALL be removed or disabled
