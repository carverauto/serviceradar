## ADDED Requirements

### Requirement: CNPG-Authoritative Identity Canonicalization
The system SHALL treat CNPG (via `IdentityEngine` + `DeviceRegistry`) as the authoritative source of canonical device identity, and SHALL NOT rely on KV as the source of truth for identity reconciliation.

#### Scenario: Registry processes updates without KV
- **WHEN** the core registry processes a batch of device updates
- **THEN** canonical device IDs are resolved and persisted via CNPG-backed identity reconciliation
- **AND** the registry does not require KV to be available to complete identity reconciliation

### Requirement: KV Identity Lookups Are Cache-Only
The system MAY use KV as a cache/hydration layer for limited identity lookups (e.g., IP and partition:IP used during sweep processing), but MUST continue to resolve identities correctly when KV is unavailable.

#### Scenario: KV miss falls back to CNPG
- **WHEN** a canonical identity lookup misses in KV
- **THEN** the system falls back to CNPG-backed lookup paths
- **AND** MAY hydrate the KV cache from the CNPG result

## REMOVED Requirements

### Requirement: Registry KV Canonical Identity Publisher
**Reason**: The KV canonical identity map publisher is disabled in normal operation due to write amplification and is not part of the current CNPG-authoritative reconciliation flow.

**Migration**: Existing KV canonical-map data (if present from older deployments) can be treated as legacy cache data and cleaned up manually using tooling/runbooks.
