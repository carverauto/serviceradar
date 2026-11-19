## ADDED Requirements

### Requirement: Core sets the broker grant cache policy
Core SHALL decide whether a credential broker grant allows memory caching of its resolved material, and SHALL record that decision on the grant when it issues it and in every grant scope it delivers.

Only core's policy sets the grant's cache policy. A Proxmox host-authority consumer defaults to memory caching because the agent host injects its credential and the Wasm guest never receives the material. Every other consumer allows memory caching only when its secret's cache policy is `memory_ttl`, and otherwise defaults to no cache. The cache TTL SHALL NOT exceed 300 seconds, the secret's configured cache TTL, the grant's TTL, the grant's expiry, or the provider lease.

These trade-offs are accepted. A rotated or disabled secret reaches an agent only after the agent's cached copy expires, which takes at most the cache TTL. A credential rule switched to another secret takes effect at once, because the switch changes the binding id and therefore the agent's cache key. A cache hit makes no resolve call, so core audits each resolution, not each use.

#### Scenario: Proxmox host-authority grant allows memory caching
- **GIVEN** a credential rule binds a Proxmox API token secret with the default `no_cache` policy to the `proxmox-inventory` plugin
- **WHEN** core materializes the assignment template and later issues the grant for a binding resolution
- **THEN** both the template's grant scope and the issued grant SHALL carry cache mode `memory_ttl`
- **AND** the cache TTL SHALL be at most 300 seconds and at most the grant's TTL

#### Scenario: Other consumer follows its secret's cache policy
- **GIVEN** a credential grant for a consumer that is not a Proxmox host-authority plugin
- **WHEN** its secret's cache policy is `no_cache` or `encrypted_ttl`
- **THEN** the grant payload SHALL NOT carry a `cache` key
- **AND WHEN** its secret's cache policy is `memory_ttl` with a 30-second cache TTL and the grant TTL is longer
- **THEN** the grant payload SHALL carry cache mode `memory_ttl` with a 30-second TTL

#### Scenario: Cache TTL never exceeds the maximum
- **GIVEN** a secret whose cache policy is `memory_ttl` with a one-hour cache TTL
- **WHEN** core issues a grant with a 900-second TTL for it
- **THEN** the grant's cache TTL SHALL be 300 seconds

#### Scenario: A descriptor cannot inject a cache policy
- **GIVEN** an integration descriptor or stored grant payload that carries its own `cache` field
- **WHEN** core builds the grant's wire payload
- **THEN** core SHALL refuse the descriptor's `cache` field as a reserved key
- **AND** the delivered payload SHALL carry only the cache policy core decided

#### Scenario: Resolve lease bounds a binding grant's cache
- **GIVEN** an agent resolves a credential by binding, so the grant scope it holds carries no expiry
- **AND** the secret is stored locally and has no provider lease
- **WHEN** core returns the resolved material
- **THEN** the response's lease SHALL equal the issued grant's expiry
- **AND WHEN** the secret has a provider lease that ends earlier than the grant
- **THEN** the response's lease SHALL equal the provider lease
