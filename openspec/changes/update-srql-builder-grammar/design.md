## Context
The network sweep targeting UI needs a visual query builder for selecting devices. The existing SRQL builder component already supports stacking multiple filter conditions with implicit AND semantics. The TargetCriteria module provides a rich operator set (eq, contains, in_cidr, has_any, etc.) that can be compiled to SRQL for query execution and preview counts.

## End-to-End Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. USER CONFIGURES SWEEP GROUP IN UI                                   │
│    - Adds targeting rules (field/operator/value)                        │
│    - Rules stored as target_criteria map on SweepGroup                  │
│    - Preview count shown via SRQL query                                 │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 2. AGENT POLLS FOR CONFIG                                              │
│    - Agent calls GetConfig RPC with partition/agent_id                  │
│    - SweepCompiler.compile() runs                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 3. TARGET LIST BUILT VIA ASH FILTERS                                   │
│    - get_targets_from_criteria() uses TargetCriteria.to_ash_filter     │
│    - Ash filters applied at database level for eq, in, contains, etc.  │
│    - Fallback to in-memory for complex ops (in_cidr, in_range, tags)   │
│    - Returns list of IP addresses matching criteria                     │
│    - Combines with static_targets                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 4. COMPILED CONFIG SENT TO AGENT                                       │
│    {                                                                    │
│      "groups": [{                                                       │
│        "id": "uuid",                                                    │
│        "targets": ["10.0.1.5", "10.0.2.10", ...],  ← IPs from query    │
│        "ports": [22, 80, 443],                                          │
│        "modes": ["icmp", "tcp"],                                        │
│        "schedule": {"type": "interval", "interval": "15m"}              │
│      }]                                                                 │
│    }                                                                    │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 5. AGENT EXECUTES SWEEP                                                │
│    - Runs ICMP/TCP scans against target IPs                            │
│    - Reports results back via agent-gateway                            │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 6. RESULTS PROCESSED                                                   │
│    - SweepResultsIngestor receives results                             │
│    - Updates ocsf_devices.is_available, last_seen                      │
│    - Creates SweepHostResult records for history                       │
└─────────────────────────────────────────────────────────────────────────┘
```

## Goals / Non-Goals
- Goals:
  - Use SRQL to execute the targeting criteria and produce the target IP list.
  - Support all device fields and operators in TargetCriteria.
  - Show accurate preview counts using the same SRQL query.
  - Keep the UI simple with stacked AND filters.
- Non-Goals:
  - Adding OR/parentheses syntax to SRQL grammar (not needed for current use cases).
  - Complex boolean expression editing (arbitrary nesting UI).
  - Changing SRQL pipeline semantics or parser.

## Decisions
- **Reuse existing builder**: The SRQL query builder component already supports stacking filters. Each filter row represents one condition, and all conditions are combined with AND (SRQL's whitespace semantics).
- **Ash filters for target extraction**: The SweepCompiler uses `TargetCriteria.to_ash_filter_with_fallback/1` to apply filters at the database level. Complex operators (in_cidr, in_range, has_any/has_all on tags) fall back to in-memory filtering. This avoids cross-app SRQL calls (SRQL uses Rust NIFs in web-ng, not available in serviceradar_core).
- **SRQL for preview counts**: The UI uses `CriteriaQuery.to_srql/1` to build queries for preview counts, ensuring the UI shows expected target numbers.
- **Shared criteria module**: `ServiceRadar.SweepJobs.CriteriaQuery` provides shared SRQL conversion used by both UI and SweepCompiler documentation.
- **Field/operator catalog**: 20 device fields exposed in targeting UI with field-appropriate operators (eq, neq, contains, in_cidr, in_range, has_any, has_all, gt/gte/lt/lte).

## Target List Change Tracking

The target result set can change even when SweepGroup config stays the same:
- New devices discovered that match criteria
- Device attributes change (discovery_sources, tags)
- Devices deleted

**How agents get updated targets:** The SweepCompiler computes targets fresh from current device inventory on each config poll. No cache invalidation is needed.

**Tracking changes for visibility:** `SweepConfigRefreshWorker` Oban job:
1. Runs every 5 minutes via cron (`*/5 * * * *` in `config_refresh` queue)
2. For each tenant's enabled sweep groups:
   - Execute Ash query to get current target IPs
   - Compute SHA256 hash of sorted IP list
   - Compare with stored `target_hash` on SweepGroup
   - If changed, update hash and log the change
3. Provides audit trail and debugging visibility

**Implementation details:**
- `SweepGroup` has `target_hash` (text) and `target_hash_updated_at` (utc_datetime) attributes
- Hash computed via `:crypto.hash(:sha256, Enum.sort(ips) |> Enum.join(","))`
- Database migration: `20260111210000_add_sweep_group_target_hash.exs`

## Risks / Trade-offs
- Stacked AND-only filters cannot express OR logic. However, for the primary use case (e.g., "devices from Armis in partition X"), this is sufficient.
- If OR support becomes necessary later, it can be added to the grammar without breaking existing queries.
- Config refresh has up to N minute delay (configurable). For most sweep use cases, this is acceptable.

## Migration Plan
1. Update SweepCompiler to use SRQL for target extraction instead of in-memory filtering.
2. Ensure all TargetCriteria operators are mapped in `criteria_to_srql_query`.
3. Verify the targeting rules UI exposes the full field/operator set.
4. Confirm preview counts match actual target lists.

## Open Questions
- None. The existing SRQL builder already meets the requirements.
