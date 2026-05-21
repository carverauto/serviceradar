## ADDED Requirements

### Requirement: Wasm plugins are not credential principals
Wasm plugins SHALL NOT be allowed to retrieve plaintext credentials directly from internal storage or external secret providers.

#### Scenario: Plugin has credential grant reference
- **GIVEN** a plugin assignment includes a broker grant reference
- **WHEN** the plugin invokes an approved host function for an allowed target
- **THEN** the agent MAY use the grant to inject credentials into the agent-owned operation
- **AND** the plugin SHALL NOT receive the plaintext credential

#### Scenario: Plugin tries direct provider access
- **GIVEN** a plugin has HTTP capability
- **WHEN** it attempts to call a secret provider endpoint directly outside its approved target allowlist
- **THEN** the agent SHALL deny the request
- **AND** the denial SHALL be reported without leaking provider auth material

### Requirement: Plugin results cannot carry credential material
Plugin result ingestion SHALL reject or redact credential material and external provider bootstrap material if a plugin attempts to include it in result details, metrics, labels, events, or display widgets.

#### Scenario: Plugin result contains secret-looking field
- **GIVEN** a plugin result includes a field named `password`, `token`, `api_key`, `secret`, `cookie`, or private key material
- **WHEN** ingestion processes the result
- **THEN** the sensitive value SHALL be redacted or the result SHALL be rejected according to policy
- **AND** an audit or diagnostic event SHALL identify the plugin assignment without storing the secret value

