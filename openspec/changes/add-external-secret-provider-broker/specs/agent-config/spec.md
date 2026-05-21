## ADDED Requirements

### Requirement: Agent config carries broker grants instead of external secret values
Agent configuration SHALL carry credential broker grants and external reference metadata required for authorized agent-side resolution, not resolved external secret values.

#### Scenario: Plugin assignment uses external reference
- **GIVEN** a plugin assignment requires a credential backed by an external secret reference
- **WHEN** the agent config response is generated
- **THEN** the assignment SHALL include a broker grant reference, reference ID, allowed target policy, and expiration
- **AND** it SHALL NOT include the external secret value or provider bootstrap credential

#### Scenario: Agent outside scope receives no grant
- **GIVEN** a credential rule is scoped to edge site `lab-a`
- **WHEN** an agent from edge site `lab-b` fetches config
- **THEN** it SHALL NOT receive the broker grant or external reference needed to resolve that credential

### Requirement: Agent broker injects credentials into owned adapters
The ServiceRadar agent SHALL resolve and inject credentials into agent-owned protocol adapters or Wasm host functions without exposing plaintext to Wasm plugin guest memory.

#### Scenario: Host HTTP request uses grant
- **GIVEN** a Wasm plugin performs an approved host HTTP request using broker grant `g1`
- **WHEN** the agent host function validates the target and grant
- **THEN** the agent SHALL apply the resolved credential to the outbound request
- **AND** the plugin SHALL receive only the HTTP response metadata/body allowed by host policy

#### Scenario: Plugin attempts to read credential
- **GIVEN** a plugin asks for credential material directly through config, params, or an unsupported host call
- **WHEN** the request reaches the agent runtime
- **THEN** the agent SHALL deny the request
- **AND** no plaintext credential SHALL be copied into plugin memory

