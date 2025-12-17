## MODIFIED Requirements

### Requirement: CNPG-Authoritative Identity Canonicalization
The system SHALL treat CNPG as the authoritative source of canonical device identity and SHALL NOT read or write KV (`device_canonical_map/*`) as part of identity resolution or sweep canonicalization.

#### Scenario: Identity works without KV
- **GIVEN** the datasvc/NATS KV system is unavailable
- **WHEN** the core processes sweep results or resolves canonical device identities
- **THEN** identity resolution continues using CNPG-backed paths and in-memory caches
- **AND** no KV identity reads or writes are required for correctness

#### Scenario: No identity KV entries are created
- **WHEN** the core runs under normal operation
- **THEN** it does not create or update `device_canonical_map/*` keys in KV
