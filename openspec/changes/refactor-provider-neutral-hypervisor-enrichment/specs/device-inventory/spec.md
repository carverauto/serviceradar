## ADDED Requirements
### Requirement: Provider-neutral hypervisor enrichment contract
The system SHALL ingest hypervisor inventory through a provider-neutral contract that supports clusters, hosts, datastores, guests, network interfaces, disks, storage systems, environmentals, and provider-specific metadata.

#### Scenario: Ingest multiple hypervisor providers through one pipeline
- **GIVEN** one Proxmox collector and one vSphere/vCenter collector emit inventory for hosts, guests, datastores, and guest NICs
- **WHEN** the inventory is ingested
- **THEN** both providers SHALL populate the shared virtualization inventory tables
- **AND** downstream UI/SRQL/alerting code SHALL query provider-neutral tables instead of provider-specific tables

#### Scenario: Preserve provider detail without using metadata as the primary model
- **GIVEN** a provider reports data that maps to shared virtualization fields and additional provider-only attributes
- **WHEN** the inventory is ingested
- **THEN** shared facts such as host status, guest state, NIC MAC/IP, datastore capacity, storage health, environmental readings, and provider refs SHALL be stored in structured fields
- **AND** metadata SHALL be used only for provider-specific details that do not yet have a shared field

### Requirement: Shared guest identity resolution
The system SHALL resolve virtualized guest devices using shared identity logic across hypervisor providers.

#### Scenario: Link guest device from any provider by MAC or IP
- **GIVEN** a hypervisor provider reports guest NIC MAC/IP evidence
- **AND** an existing inventory device has matching device identifiers in the same partition
- **WHEN** hypervisor enrichment is ingested
- **THEN** the guest SHALL link to the canonical device using the shared identity resolver
- **AND** provider-specific ingestors SHALL NOT duplicate MAC/IP/name matching logic

#### Scenario: Avoid provider-specific identity forks
- **GIVEN** Proxmox and vSphere report equivalent guest identity evidence in different native API shapes
- **WHEN** each provider adapter emits the shared hypervisor envelope
- **THEN** the shared identity resolver SHALL apply the same precedence and confidence rules
- **AND** provider adapters SHALL NOT implement their own canonical device matching beyond normalizing provider API fields into the envelope

### Requirement: Provider-neutral virtualization UI and alerting inputs
The system SHALL expose virtualization inventory and metrics to UI, SRQL, and alerting through provider-neutral fields with optional provider-specific drilldown metadata.

#### Scenario: Display hypervisor inventory for different providers
- **GIVEN** device detail data includes Proxmox and vSphere virtualization records
- **WHEN** the device details page, dashboard panels, or alerting rules query virtualization inventory
- **THEN** they SHALL use provider-neutral resource, status, metric, and relationship fields
- **AND** provider-specific names SHALL be limited to labels, badges, or drilldown metadata.

#### Scenario: Define alerts against any hypervisor provider
- **GIVEN** virtualization metrics or health observations are collected from Proxmox and vSphere hosts
- **WHEN** an operator creates an alert rule for host CPU, memory, storage capacity, environmental health, or guest state
- **THEN** the rule SHALL target provider-neutral metric and relationship fields
- **AND** the provider SHALL be an optional filter rather than a required rule type.
