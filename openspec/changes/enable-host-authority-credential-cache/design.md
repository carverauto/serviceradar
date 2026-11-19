# Design: Core sets the cache policy on credential broker grants

## Decision 1: the grant stores its cache policy

The agent reads the cache policy from the grant payload. For an embedded grant
that payload is `CredentialBrokerGrant.to_payload/2` of an issued row, which is
a pure function, so the row must carry the policy. Two columns,
`cache_mode` and `cache_ttl_seconds`, hold it, and a check constraint keeps the
pair consistent (`no_cache` with no TTL, `memory_ttl` with 1 to 300 seconds).

## Decision 2: the issue action decides, callers do not

`cache_mode` and `cache_ttl_seconds` are not accepted inputs of the issue
action. The `ApplyGrantCachePolicy` change loads the secret's policy fields and
sets both through `GrantCachePolicy.cache_attrs/2`. Every issuer (config
delivery, resolve by binding, schedule dispatch, automation, notifications,
declarative checks) therefore gets the same decision, and none can widen it.

`"cache"` is also a reserved payload key, so a descriptor's payload extension
cannot add it to the wire form, and `CredentialBrokerDelivery` drops it from a
stored payload before re-minting.

## Decision 3: the template carries the policy too

An agent that resolves by binding receives only the grant's scope from the
assignment template, never the issued grant. So the materializer applies the
same `GrantCachePolicy.put/2` to the scope before `scope_payload/2`. It reads
the secret's policy from the rule, which `rules_for_agent_scope/5` now loads
with only the secret's `id`, `cache_policy` and `cache_ttl_seconds`. No extra
query runs per template, and the materializer stays free of a secret lookup.

## Decision 4: reuse compares the current policy

`reuse_or_issue/2` matches candidates on the full wire scope, which now
includes `"cache"`. Its input attrs come from a payload that has had `cache`
dropped, so it applies the current policy to them before comparing. A grant
issued under an older policy stops matching and a new one is issued.

## Decision 5: the resolve lease bounds the cache by the grant

The agent clamps its cache entry to `lease_expires_at_unix`. A binding scope
has no expiry, and a local CNPG secret has no provider lease, so that field was
0 and nothing core issued bounded the cache. `AgentGatewaySync` now returns the
earlier of the provider lease and the issued grant's expiry. `SecretBroker`
already clamps an external provider's lease to the grant expiry, so the change
matters for local secrets. Core reuses a binding grant only while 60 seconds
remain, so the agent never receives a lease already in the past.

## Rejected: keying host-authority caching off the template alone

Setting `cache` only in `ProxmoxHostAuthority.scope_grant_to_origin/5` would
work for bindings, but it would ignore the secret's `cache_ttl_seconds`, leave
embedded grants uncached, and leave the other consumers' secret policy unread.
