## ADDED Requirements
### Requirement: Hypervisor plugin adapter contract
Hypervisor plugins SHALL act as provider adapters that emit a shared hypervisor enrichment envelope and may include provider-specific metadata only where the shared contract has no equivalent field.

#### Scenario: Add a new vSphere/vCenter plugin
- **GIVEN** a vSphere/vCenter plugin collects host, cluster, datastore, guest, and guest NIC data
- **WHEN** the plugin emits results
- **THEN** it SHALL use the shared hypervisor enrichment schema
- **AND** core ingestion SHALL not require a new provider-specific ingestion pipeline for common virtualization records

#### Scenario: Keep provider logic inside adapters
- **GIVEN** a hypervisor plugin uses provider-specific API endpoints, authentication flows, or object names
- **WHEN** it returns inventory to ServiceRadar
- **THEN** provider-specific API shapes SHALL be normalized before shared ingestion
- **AND** shared agent runtime, core ingestion, UI, SRQL, and alerting code SHALL not branch on provider except for adapter selection, labels, or provider-only drilldowns

### Requirement: Generic remote-console target contract
Console-capable plugins SHALL use a shared remote-console target contract and protocol/provider-specific transport adapters.

#### Scenario: Open console for supported target
- **GIVEN** a device, hypervisor host, or virtual guest has remote-console target metadata and a scoped credential rule
- **WHEN** an operator opens a console session
- **THEN** the system SHALL create the session through generic authorization and credential broker code
- **AND** the selected agent-side protocol/provider transport adapter SHALL handle Proxmox SSH/termproxy/VNC, plain SSH, vSphere console behavior, or future RDP behavior without exposing credentials to the browser.

#### Scenario: Audit console sessions consistently across providers
- **GIVEN** an operator opens a console to a Proxmox guest, vSphere VM, Linux device over SSH, or future Windows host over RDP
- **WHEN** the session is created, resized, closed, or fails
- **THEN** the system SHALL record generic remote-console audit events with actor, device, optional provider, target ref, protocol, credential rule, gateway, agent, and session outcome
- **AND** the audit record SHALL NOT include plaintext credentials or terminal byte contents.

### Requirement: Provider-neutral hypervisor credential rules
Hypervisor plugins SHALL consume scoped credential rules using shared provider and purpose fields instead of provider-specific credential plumbing.

#### Scenario: Scope credentials for inventory collection
- **GIVEN** an operator creates a hypervisor credential rule for provider `proxmox` or `vsphere`
- **WHEN** the rule is assigned to an agent and SRQL scope
- **THEN** the generated plugin assignment SHALL include credential broker references scoped to that agent, provider, purpose, and target scope
- **AND** plaintext secrets SHALL NOT be delivered to unrelated agents or stored in plugin package schemas.
