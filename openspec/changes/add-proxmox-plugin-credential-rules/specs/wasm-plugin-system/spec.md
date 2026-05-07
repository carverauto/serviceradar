## ADDED Requirements

### Requirement: Plugin credential inputs are brokered and typed
The plugin runtime SHALL support scoped, typed credential broker grants for credential-rule-driven assignments while preserving redaction and allowlist enforcement.

#### Scenario: Runtime supplies scoped Proxmox broker grant
- **GIVEN** a Proxmox plugin assignment was compiled from a credential rule
- **WHEN** the plugin starts
- **THEN** the runtime SHALL provide only a broker grant, target metadata, and credential reference required for that assignment
- **AND** decrypted token, password, private key, ticket, cookie, and CSRF values SHALL NOT be supplied directly to the plugin
- **AND** the plugin SHALL still access the target only through approved host functions

### Requirement: Plugin results cannot persist secrets
The plugin result ingestion pipeline SHALL reject or sanitize credential-bearing fields in plugin result payloads.

#### Scenario: Plugin accidentally returns token value
- **GIVEN** a plugin result details payload contains a field that matches a scoped secret value
- **WHEN** ingestion validates the result
- **THEN** the secret SHALL be redacted or the result SHALL be rejected according to policy
- **AND** the raw secret SHALL NOT be stored in CNPG, logs, events, or inventory enrichment

### Requirement: Console access is outside plugin execution
Interactive console sessions SHALL be handled by the authorized console broker path and SHALL NOT run inside the WASM plugin sandbox.

#### Scenario: Proxmox plugin reports console capability only
- **GIVEN** the Proxmox plugin discovers a PVE host or guest that may support console access
- **WHEN** the plugin emits enrichment
- **THEN** it MAY report non-secret console capability hints
- **AND** it SHALL NOT open an interactive terminal session or receive SSH private key material for an interactive session
