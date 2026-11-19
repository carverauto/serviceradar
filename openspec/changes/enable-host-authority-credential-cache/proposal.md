# Change: Core sets the cache policy on credential broker grants

## Why

The agent already caches resolved broker material in memory when a grant
carries `cache.mode` `memory`, `memory_only` or `memory_ttl`, bounded by the
cache TTL, the grant's TTL and expiry, and the lease returned with the material.
Core never sets `cache`, so no grant is ever cached.

For the Proxmox inventory plugin that means one `ResolveCredentialGrant` call
per Proxmox API request, about 70 per run per target. Each call makes core
reload the assignment, rebuild the binding, reuse or issue a grant, decrypt the
secret and write a `credential_secret_resolution_audits` row. That costs core
tens to hundreds of milliseconds per call and produces thousands of audit rows
an hour for material that did not change.

`NetworkCredentialSecret.cache_policy` and `cache_ttl_seconds` exist but nothing
reads them. And a grant resolved by binding reaches the agent as scope only,
without an expiry, while a local CNPG secret has no provider lease, so the
resolve response gives the agent no bound from core at all.

## What Changes

- Grants gain `cache_mode` (`no_cache` or `memory_ttl`) and
  `cache_ttl_seconds`. The issue action sets both from the consumer and the
  secret; callers cannot supply them.
- Proxmox host-authority consumers (`proxmox-inventory`, `proxmox-console`)
  default to `memory_ttl`. The agent host injects their credential, so the
  material never enters guest memory.
- Every other consumer follows its secret's `cache_policy`, and only
  `memory_ttl` enables caching. Its default stays `no_cache`. `encrypted_ttl`
  does not enable an agent cache, because agents have no encrypted cache.
- The cache TTL is the secret's `cache_ttl_seconds`, defaulting to and capped
  at 300 seconds, and never longer than the grant's TTL.
- The wire payload carries `"cache"` when caching is allowed, and `cache`
  becomes a reserved payload key, so an integration descriptor cannot inject it.
- Materialized assignment templates carry the same cache policy in the grant
  scope, because an agent that resolves by binding never sees the issued grant.
- The resolve response's `lease_expires_at_unix` becomes the earlier of the
  provider lease and the issued grant's expiry, so a binding grant's cache can
  never outlive the grant.
- The grant-reuse comparison includes the cache policy the issue action would
  set now.

Accepted trade-offs:

- Rotating or disabling a secret reaches an agent only after its cached copy
  expires, at most the cache TTL. Swapping a credential rule to another secret
  takes effect at once, because the swap changes the binding id and therefore
  the agent's cache key.
- A cache hit makes no resolve call, so core audits each resolution, not each
  use.

## Impact

- Affected spec: `platform-security`. This change adds a core-side requirement.
  The agent-side requirement "Broker credential material caching is explicit
  and bounded" still lives only in the pending change
  `add-external-secret-provider-broker`, so its lease bound is amended there.
- Affected code: `CredentialBrokerGrant` (attributes, issue action, payload,
  reuse), new `GrantCachePolicy` and `ApplyGrantCachePolicy`,
  `PluginAssignmentMaterializer` (loads each rule's secret policy),
  `ProxmoxHostAuthority.host_injected_consumer?/2`, and
  `AgentGatewaySync` (resolve lease).
- Migration: adds `cache_mode` and `cache_ttl_seconds` to
  `platform.credential_broker_grants`, with a check constraint on the pair.
- Rollout: the cache policy changes each Proxmox assignment's template once, so
  each affected assignment is rewritten once and its host-bindings fingerprint
  changes once, which restarts that plugin runner once. Live grants issued
  before the upgrade no longer match the reuse scope, so each binding gets one
  new grant.
- Agents: no change. Existing agents already honor `cache` and clamp it to the
  resolve lease.
