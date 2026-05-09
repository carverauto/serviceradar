## ADDED Requirements
### Requirement: ZFS Storage Enrichment Collection
The sysmon library SHALL collect ZFS pool, dataset, and vdev facts on supported Linux hosts when ZFS collection is enabled and the host exposes the required ZFS tooling or kernel data.

#### Scenario: ZFS collection on a PVE host
- **GIVEN** sysmon runs on a Linux Proxmox host with ZFS collection enabled
- **WHEN** a collection cycle runs
- **THEN** sysmon SHALL report ZFS pool health, capacity, allocation, and fragmentation when available
- **AND** it SHALL report dataset names, mountpoints, usage, quota, reservation, and compression details when available
- **AND** it SHALL report vdev health, path/by-id, size, and read/write/checksum error counters when available

#### Scenario: ZFS is unavailable
- **GIVEN** sysmon runs on a host without ZFS tooling or pools
- **WHEN** ZFS collection is enabled
- **THEN** sysmon SHALL continue collecting other metrics
- **AND** it SHALL report the ZFS collection as unavailable without failing the whole sample

### Requirement: ZFS Payload Compatibility
The sysmon library SHALL emit ZFS observations in a normalized payload that can be converted into provider-neutral hypervisor storage records.

#### Scenario: Agent host is a hypervisor
- **GIVEN** the agent host is linked to a canonical hypervisor device
- **WHEN** sysmon emits ZFS observations
- **THEN** the payload SHALL include enough host identity context for core ingestion to attach the records to that canonical device
- **AND** it SHALL include pool, dataset, vdev, disk path, and disk by-id evidence when available

#### Scenario: Sysmon runs on a non-hypervisor server
- **GIVEN** sysmon emits ZFS observations for a normal server
- **WHEN** the payload is ingested
- **THEN** the storage records SHALL remain attached to the server device
- **AND** the ingestion path SHALL NOT classify the server as a hypervisor solely because ZFS exists
