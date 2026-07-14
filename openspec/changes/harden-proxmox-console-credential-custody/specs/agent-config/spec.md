## ADDED Requirements

### Requirement: Proxmox credentials remain in host-only assignment state
The system SHALL deliver Proxmox inventory and console broker grants through a typed agent-host-only assignment envelope that is not exposed to Wasm. Wasm-visible configuration SHALL NOT contain a Proxmox API token, password, SSH private key, passphrase, provider ticket, cookie, CSRF value, ServiceRadar bearer token, resolved secret, redeemable secret reference, broker grant, or other value that grants credential authority.

#### Scenario: Inventory assignment reaches compatible agent
- **GIVEN** the control plane has a Proxmox inventory assignment with an external-secret broker grant
- **AND** the target agent advertises the host-only Proxmox assignment capability
- **WHEN** the control plane renders the assignment
- **THEN** the grant, secret reference, target policy, and resolver authority SHALL be placed only in the typed host-only envelope
- **AND** Wasm `get_config` SHALL receive only non-secret semantic operation inputs and presentation settings
- **AND** the host-only envelope SHALL NOT be projected into plugin callbacks, environment variables, plugin-visible diagnostics, or persisted Wasm parameters

#### Scenario: Console assignment reaches compatible agent
- **GIVEN** an authorized console session has an actor-bound, one-session credential grant
- **WHEN** the assignment reaches a compatible agent
- **THEN** the session grant SHALL be delivered only to trusted agent host code
- **AND** Wasm SHALL NOT receive the grant ID, credential rule authority, secret reference, resolved credential, provider ticket, or protected connector fields

#### Scenario: Secret appears in Wasm-visible parameters
- **GIVEN** a Proxmox assignment includes a raw credential, redeemable reference, broker grant, protected authorization field, or provider ticket in Wasm-visible parameters
- **WHEN** the control plane or agent validates the assignment
- **THEN** the assignment SHALL be rejected
- **AND** no resolver or network connector SHALL be invoked
- **AND** the rejection SHALL be audited without copying the offending value

### Requirement: Proxmox assignment versions fail closed
The system SHALL negotiate explicit versions for host-only credential delivery, semantic Proxmox connectors, assignment policy bindings, and source-scoped virtualization identities. Each host binding SHALL carry a positive policy version and deterministic assignment-policy fingerprint that the agent recomputes from the assignment ID, plugin ID, entrypoint, policy ID, policy version, and credential-rule ID. It SHALL NOT preserve authenticated Proxmox inventory or console operation by falling back to legacy inline-secret delivery or authoritative v1/v2 identities.

#### Scenario: New control plane targets old agent
- **GIVEN** the target agent does not advertise all required Proxmox security capabilities
- **WHEN** the control plane reconciles an authenticated inventory or console assignment
- **THEN** it SHALL mark the assignment unavailable with an upgrade-required reason
- **AND** it SHALL NOT emit an inline token, secret reference, generic credential-bearing HTTP request, or legacy identity fallback

#### Scenario: New agent receives legacy credential fields
- **GIVEN** a new agent receives an old Proxmox assignment containing Wasm-visible credential material or broker authority
- **WHEN** it parses the assignment
- **THEN** it SHALL reject the assignment before plugin startup, secret resolution, or network dial
- **AND** it SHALL emit only a redacted incompatibility event

#### Scenario: Legacy identity has not migrated
- **GIVEN** a Proxmox assignment refers only to a v1 or v2 provider identity that has no unambiguous v3 mapping
- **WHEN** authenticated inventory or console execution is requested
- **THEN** the system SHALL deny execution
- **AND** it SHALL require identity migration rather than infer a source from a name, IP, URL, node, or VMID

#### Scenario: New agent receives an older host binding
- **GIVEN** an agent requires the assignment policy version and fingerprint fields
- **WHEN** it receives a host authority binding that omits either field or does not match the public assignment policy
- **THEN** strict parsing and binding validation SHALL reject the assignment before plugin startup, credential resolution, or network dial
- **AND** no compatibility default SHALL synthesize the missing policy binding

#### Scenario: Older agent receives a newer host binding
- **GIVEN** an older agent strictly parses the prior host authority schema
- **WHEN** a newer control plane includes the required assignment-policy or SSH host-key policy fields
- **THEN** the older parser SHALL reject the unknown fields and leave authenticated Proxmox execution unavailable
- **AND** the control plane SHALL NOT retry with an inline secret or weaker host binding

#### Scenario: Compatible agent acknowledges one exact parsed console assignment
- **GIVEN** trusted agent host code successfully parsed a Proxmox console host binding from a committed config version
- **WHEN** the agent sends a config acknowledgement or subsequent authenticated control-stream hello
- **THEN** it SHALL advertise `plugin-host-authority:v1`, `proxmox-semantic-connector:v1`, `proxmox-identity:v3`, and `proxmox-console-policy-binding:v1`
- **AND** it SHALL report the committed config version and exact assignment ID, plugin ID, positive policy version, and policy fingerprint from trusted host state
- **AND** browser fields, plugin results, and console JSON SHALL NOT contribute to that evidence

#### Scenario: Broker sees incomplete mixed-version evidence
- **GIVEN** the live authenticated control session omits a required capability, committed config version, or exact parsed assignment proof
- **OR** the persisted agent record omits a required capability, has not acknowledged that same config version, or has a different pushed version pending
- **WHEN** the control plane attempts to open a Proxmox console
- **THEN** the broker SHALL deny before subscribing or sending an open frame
- **AND** it SHALL NOT fall back to plugin-reported capability, legacy config fields, or a weaker assignment

#### Scenario: Active streaming assignment is revoked
- **GIVEN** a Proxmox console execution captured one exact assignment generation
- **WHEN** config application removes the assignment or changes its stable generation while credential resolution or connection setup is in progress
- **THEN** the agent SHALL cancel the old execution
- **AND** trusted HTTP, WebSocket, and SSH paths SHALL recheck the exact active generation immediately before resolution and dial
- **AND** no network dial SHALL occur after the generation is revoked
