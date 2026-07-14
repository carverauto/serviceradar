## ADDED Requirements

### Requirement: Proxmox broker grants are exact-use capabilities
The credential broker SHALL treat every Proxmox grant as a non-transferable capability bound to its declared actor or assignment, provider source, target, purpose, operation, agent route, lifetime, and use count. The broker SHALL reject a missing, stale, ambiguous, or mismatched binding before returning credential material.

#### Scenario: Inventory operation matches grant
- **GIVEN** an inventory grant is bound to an assignment version, integration, controller, v3 provider target, `inventory_enrichment` purpose, agent, gateway, semantic operation set, target-policy digest, expiry, and maximum uses
- **WHEN** the trusted agent connector requests an allowed operation with every binding equal
- **THEN** the broker MAY resolve the credential directly to the trusted connector
- **AND** it SHALL record the grant use without returning the secret or grant authority to Wasm

#### Scenario: Console operation matches grant
- **GIVEN** a console grant is additionally bound to the current actor, authorization decision, session, device, credential rule, cluster, node, VMID/type, console mode, canonical origin, and one-use limit
- **WHEN** the trusted console connector requests credential material for that exact session
- **THEN** the broker MAY resolve one-session material directly to the connector
- **AND** the grant SHALL be consumed according to its one-use policy

#### Scenario: Binding is substituted
- **GIVEN** any actor, authorization decision, assignment/version, session, device, provider identity, integration, controller, cluster, node, VMID/type, credential rule, purpose, agent, gateway, operation/mode, target policy, origin, expiry, or use count differs from the grant
- **WHEN** resolution is attempted
- **THEN** the broker SHALL deny the request before reading or returning the secret
- **AND** it SHALL NOT retry with a broader grant, service credential, default target, or legacy identity

### Requirement: Proxmox secrets are injected only into trusted connectors
The broker SHALL deliver resolved Proxmox and SSH credential material only into memory owned by the trusted agent connector that will perform the authorized effect. It SHALL NOT return that material through a Wasm host-call result, plugin configuration, console metadata, assignment status, audit event, metric, log, error, crash report, or persisted agent state.

#### Scenario: Trusted connector resolves token
- **GIVEN** a grant has passed authorization and exact-binding validation
- **WHEN** the broker resolves a Proxmox token
- **THEN** the token SHALL be applied by trusted host code to the exact authorized request
- **AND** the connector SHALL discard it after the bounded use
- **AND** Wasm SHALL receive only a non-secret semantic result

#### Scenario: Provider returns console ticket
- **GIVEN** the trusted connector creates a Proxmox native console ticket
- **WHEN** it opens the exact authorized WebSocket
- **THEN** the ticket, cookie, and CSRF values SHALL remain host-owned and session-bound
- **AND** they SHALL NOT be returned to Wasm, the browser, or general console metadata

#### Scenario: Resolution fails
- **GIVEN** an external secret provider or connector fails
- **WHEN** the failure is reported
- **THEN** the system SHALL expose only a bounded phase, safe reason code, and correlation ID
- **AND** provider error text SHALL be sanitized before it reaches plugin-visible or operator-visible surfaces
