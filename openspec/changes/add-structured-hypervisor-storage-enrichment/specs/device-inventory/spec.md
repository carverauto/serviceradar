## ADDED Requirements
### Requirement: Structured Hypervisor Storage Inventory
The system SHALL store hypervisor storage pools, datasets, and vdevs as structured provider-neutral inventory records instead of relying on provider-specific metadata for common health and capacity fields.

#### Scenario: Proxmox and sysmon enrich the same PVE host storage
- **GIVEN** Proxmox enrichment reports a datastore or host disk for a PVE node
- **AND** sysmon running on that PVE node reports ZFS pool, dataset, or vdev details
- **WHEN** the enrichment records are ingested
- **THEN** the records SHALL be associated with the same canonical hypervisor host device when identity evidence matches
- **AND** common fields such as health, status, capacity, allocation, disk path, and disk by-id SHALL be stored in structured columns
- **AND** provider-only fields MAY be retained in sanitized metadata

#### Scenario: Future hypervisor providers emit storage records
- **GIVEN** a vSphere/vCenter adapter reports datastores and backing storage health
- **WHEN** it emits the shared hypervisor enrichment envelope
- **THEN** the same storage pool, dataset, or vdev resources SHALL be used where the facts map to shared fields
- **AND** web-ng and SRQL SHALL not require provider-specific parsing for common storage health and capacity views

### Requirement: Storage Correlation Evidence
The system SHALL correlate hypervisor and host-local storage observations using durable identity evidence before merging records.

#### Scenario: Storage records share strong evidence
- **GIVEN** a sysmon ZFS pool record and a Proxmox datastore record share a hypervisor host device UID
- **AND** the pool or dataset name matches the datastore name or backing storage metadata
- **WHEN** storage enrichment is persisted
- **THEN** the records SHALL be linked as related observations of the same host storage

#### Scenario: Storage records lack strong evidence
- **GIVEN** a sysmon ZFS pool record and a hypervisor datastore record only share a display name
- **AND** they do not share host identity, provider refs, disk path, disk by-id, or another durable join key
- **WHEN** storage enrichment is persisted
- **THEN** the system SHALL keep them as separate records
- **AND** it SHALL not reassign canonical devices based only on the shared display name

### Requirement: Storage Drilldowns And Alerts
The system SHALL expose structured hypervisor storage health and pressure data to device details, dashboards, SRQL, and alert rule inputs.

#### Scenario: Operator investigates virtualization pressure
- **GIVEN** the dashboard virtualization panel shows storage pressure
- **WHEN** the operator opens the pressure sources
- **THEN** storage pool, dataset, datastore, or vdev records contributing to pressure SHALL be shown as drilldown targets

#### Scenario: Operator defines a storage alert
- **GIVEN** structured storage pool, dataset, or vdev records exist
- **WHEN** an operator creates an alert rule for storage capacity, health, or vdev error counters
- **THEN** the rule SHALL use structured fields rather than requiring JSON metadata parsing
