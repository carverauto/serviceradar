## 1. Grant cache policy

- [x] 1.1 Add `cache_mode` and `cache_ttl_seconds` to `CredentialBrokerGrant` with a migration and a check constraint on the pair.
- [x] 1.2 Add `GrantCachePolicy`: host-authority consumers default to `memory_ttl`, other consumers follow the secret's `cache_policy`, and the TTL is capped at 300 seconds and the grant TTL.
- [x] 1.3 Set the policy in the issue action (`ApplyGrantCachePolicy`); do not accept it from callers.
- [x] 1.4 Emit `"cache"` from `to_payload/2` and reserve the key against payload extensions.
- [x] 1.5 Compare the current cache policy in `reuse_or_issue/2`.

## 2. Templates and resolution

- [x] 2.1 Load each rule's secret cache policy in the materializer and apply it to the template's grant scope.
- [x] 2.2 Return the earlier of the provider lease and the issued grant's expiry as the resolve lease.

## 3. Verification

- [x] 3.1 Materializer test: the template scope carries the cache policy for host-authority and other consumers, including the 300-second cap and the no-cache cases.
- [x] 3.2 Payload test: a `cache` payload extension is refused.
- [x] 3.3 DB test: a binding-resolved Proxmox grant carries `memory_ttl` within the grant TTL, is still reused, and the resolve lease equals the grant's expiry for a local secret.
- [ ] 3.4 After rollout, confirm Proxmox inventory resolve calls and resolution audit rows drop to about one per binding per cache TTL.
