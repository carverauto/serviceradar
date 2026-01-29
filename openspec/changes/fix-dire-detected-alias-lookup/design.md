## Context

DIRE (Device Identity and Reconciliation Engine) uses IP aliases to correlate device updates across different discovery sources. Aliases progress through states: `detected` → `confirmed` → `updated`/`stale`/`archived`. The confirmation threshold (default: 3 sightings) prevents spurious aliases from polluting the identity graph.

However, the current implementation creates a race condition where sweep results can arrive before an alias is confirmed, creating duplicate devices that are never reconciled.

### Stakeholders
- Platform operators seeing duplicate devices in inventory
- Sweep job processing pipeline
- Identity reconciliation engine

### Constraints
- Cannot simply remove the confirmation threshold (would allow single-sighting aliases to cause false merges)
- Must maintain performance of batch device lookup (avoid N+1 queries)
- Solution should work with existing Ash resource patterns

## Goals / Non-Goals

### Goals
- Prevent duplicate device creation when a detected alias exists
- Maintain alias confirmation threshold for general correctness
- Allow sweep results to serve as strong confirmation signals
- Keep batch lookup performance O(1) database queries

### Non-Goals
- Changing the default confirmation threshold
- Retroactive deduplication in this change (handled by scheduled reconciliation)
- UI changes for alias visualization

## Decisions

### Decision 1: Two-tier alias lookup

When looking up devices by IP, use a two-tier approach:

1. **Primary lookup**: Check for `confirmed` or `updated` aliases (current behavior)
2. **Fallback lookup**: If no match AND creating a new device, check `detected` aliases

The fallback only activates when we would otherwise create a new device, minimizing performance impact.

**Alternatives considered:**
- Lower threshold to 1: Too aggressive, may cause false merges from transient IPs
- Always include detected aliases in primary lookup: Performance concern for large alias sets
- Async reconciliation only: Duplicates exist in inventory until next reconciliation run

### Decision 2: Sweep results auto-confirm detected aliases

When a sweep result matches a `detected` alias, promote it to `confirmed` immediately. Rationale:
- Sweep results represent direct network evidence of an IP being active
- The combination of (interface discovery IP + sweep result for same IP) is strong evidence
- Waiting for 3 sightings from a single source (mapper) is overly conservative

**Implementation:**
```elixir
# In DeviceAliasState
update :confirm_from_sweep do
  description "Promote detected alias to confirmed via sweep match"
  accept [:metadata]

  change set_attribute(:state, :confirmed)
  change atomic_update(:last_seen_at, expr(now()))
  change atomic_update(:sighting_count, expr(sighting_count + 1))
end
```

### Decision 3: Create aliases for new sweep devices

When a sweep device IS created (no alias match found), create a `detected` alias for it. This ensures:
- Future interface discoveries that find the same IP can merge the devices
- The scheduled reconciliation job can identify potential duplicates

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Detected alias might point to wrong device | Sweep confirmation requires the IP to be reachable, increasing confidence |
| Performance impact from fallback query | Fallback only triggers when creating new device (rare path after initial discovery) |
| Alias churn during network changes | Existing alias lifecycle (stale → archived) handles IP reassignment |

## Migration Plan

1. Deploy code changes
2. Scheduled reconciliation will automatically merge existing duplicates on next run
3. No data migration required - new behavior is additive

### Rollback
Revert code changes. Duplicates created during deployment will be cleaned up by scheduled reconciliation once the threshold-based confirmation resumes working.

## Open Questions

1. Should we add metrics/telemetry for detected alias matches vs new device creation?
2. Should the confirmation threshold be configurable per-partition or globally only?
