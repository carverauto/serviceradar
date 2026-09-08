## ADDED Requirements
### Requirement: Credential-free Proxmox candidate discovery
The mapper discovery engine SHALL support unauthenticated Proxmox VE candidate fingerprinting within configured discovery scope without requiring any Proxmox credential rule. Authenticated enrichment and credential trials SHALL remain separate from candidate fingerprinting.

#### Scenario: Discover PVE candidate before credentials exist
- **GIVEN** a mapper job assigned to an agent includes a seed that reaches a host running the Proxmox VE web/API service on port 8006
- **AND** no Proxmox credential rule exists
- **WHEN** the mapper job runs with Proxmox candidate probing enabled for that job or site scope
- **THEN** the discovered device SHALL be marked with `metadata.proxmox_candidate:true`
- **AND** candidate evidence SHALL include non-secret fingerprint details such as port, response title, fingerprint source, and observed time
- **AND** no credential material SHALL be requested or transmitted

#### Scenario: Credential trials require explicit opt-in
- **GIVEN** a Proxmox credential rule is scoped to `agent-sr-test-pve04`
- **AND** `allow auto-discovery credential trials` is disabled
- **WHEN** a Proxmox candidate is discovered by that agent
- **THEN** the system SHALL NOT try the credential against the candidate unless the candidate also matches the rule SRQL target query

#### Scenario: Auto-discovery credential trials stay scoped
- **GIVEN** a Proxmox credential rule is scoped to `agent-sr-test-pve04`
- **AND** `allow auto-discovery credential trials` is enabled
- **WHEN** candidates are discovered by multiple agents
- **THEN** the scoped credential MAY be tried only against candidates discovered within `agent-sr-test-pve04` scope
- **AND** candidates outside that scope SHALL NOT receive credential grants
