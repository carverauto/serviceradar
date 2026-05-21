## ADDED Requirements

### Requirement: External secret provider access is least-privilege and audited
External secret provider access SHALL be authorized with least-privilege provider credentials and audited at provider, reference, target, consumer, and actor levels.

#### Scenario: Provider credential lacks object permission
- **GIVEN** a provider bootstrap credential cannot read a referenced object
- **WHEN** a broker resolution is attempted
- **THEN** the broker SHALL classify the failure as unauthorized or policy denied
- **AND** the audit event SHALL omit provider bootstrap credential values and resolved secret values

### Requirement: Secret provider metadata is access-controlled
Provider endpoint, object path, field mapping, and username metadata SHALL be treated as sensitive administrative metadata unless explicitly marked safe to show.

#### Scenario: Non-admin views credential consumer
- **GIVEN** a non-admin user can view a service or plugin result
- **WHEN** that object uses an external secret reference
- **THEN** the UI/API SHALL NOT reveal provider object paths, bootstrap auth metadata, field names marked sensitive, or resolved secret values

### Requirement: Broker fails closed on unavailable external secret
Credential consumers SHALL fail closed when required external secrets cannot be resolved and no explicit cache grace policy permits temporary use of a cached value.

#### Scenario: Required secret server is unavailable
- **GIVEN** a plugin check requires a credential from an external provider
- **WHEN** the provider is unreachable and no cache grace policy applies
- **THEN** the check SHALL fail with a credential resolution status
- **AND** it SHALL NOT run anonymously or with stale unrelated credentials

### Requirement: Broker credential material caching is explicit and bounded
Credential consumers SHALL default to no cache for resolved credential material unless a broker grant explicitly allows short memory-only caching.

#### Scenario: Agent resolves a broker grant without cache policy
- **GIVEN** an agent-owned plugin host function resolves a credential broker grant
- **WHEN** the grant does not include an explicit memory cache policy
- **THEN** each broker use SHALL call the resolver
- **AND** plaintext credential material SHALL NOT be stored in durable config, logs, results, or plugin memory

#### Scenario: Agent resolves a broker grant with memory cache policy
- **GIVEN** an agent-owned plugin host function resolves a credential broker grant with memory-only caching enabled
- **WHEN** the grant is reused before the cache TTL and grant expiry
- **THEN** the agent MAY reuse memory-only credential material
- **AND** the cache TTL SHALL be bounded by the grant expiry and a short maximum TTL
- **AND** expired cached material SHALL be discarded before reuse
