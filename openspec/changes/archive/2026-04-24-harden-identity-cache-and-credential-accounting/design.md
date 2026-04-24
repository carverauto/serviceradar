## Context
The current identity cache uses a plain ETS set keyed by lookup key and evicts oversized tables by calling `:ets.tab2list/1`, sorting all entries, and deleting the oldest 10 percent. That pattern is acceptable for small tables but becomes a self-DoS vector at the configured 100k-entry ceiling.

Access credential accounting currently performs a read-modify-write increment in a non-atomic function change. Under concurrent token or OAuth client usage, incremented `use_count` values are lost.

The first-user bootstrap path performs a count query during registration and promotes the registrant to admin when the count is zero. Two concurrent first registrations can both observe zero and both become admin.

## Goals
- Prevent oversized identity cache eviction from copying the full ETS table into one process.
- Make credential use counters accurate under concurrency.
- Ensure only one initial user is promoted to admin during bootstrap.

## Non-Goals
- Replacing the identity cache with an external cache.
- Reworking the broader authentication model or adding new user roles.
- Changing the existing rate-limiting behavior for login endpoints.

## Decisions

### Identity Cache Eviction
The cache should stop using `:ets.tab2list/1` for eviction. A bounded approach should inspect only a limited slice of entries at a time or maintain eviction metadata in a way that avoids full materialization. The specific implementation can stay internal as long as eviction remains bounded in memory and CPU.

### Credential Usage Accounting
`use_count` updates should use Ash atomic update semantics instead of read-modify-write Elixir code. `last_used_at` and `last_used_ip` can still be updated in the same action as long as the counter increment stays atomic.

### First User Bootstrap
First-user admin assignment should rely on a deterministic guarded write path instead of a read-then-decide count check. The implementation can use a transaction/lock or database-enforced singleton-style guard, but it must fail closed against concurrent duplicate admin promotion.
