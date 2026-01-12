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
│ 3. SRQL QUERY EXECUTED TO BUILD TARGET LIST                            │
│    - compile_targets() converts target_criteria to SRQL                 │
│    - Executes: in:devices {criteria_query} select:ip                    │
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
│        "targets": ["10.0.1.5", "10.0.2.10", ...],  ← IPs from SRQL     │
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
- **SRQL for target extraction**: The SweepCompiler should use SRQL (not in-memory filtering) to extract target IPs. This ensures the preview count and actual target list are always consistent.
- **Field/operator catalog**: Expose device-relevant fields (partition, discovery_sources, tags, ip, hostname, etc.) and operators (eq, neq, contains, in_cidr, in_range, has_any, has_all) in the targeting rules UI.
- **Criteria-to-SRQL conversion**: The existing `criteria_to_srql_query/1` function in networks_live handles conversion. Ensure all TargetCriteria operators are covered.

## Config Invalidation on Device Changes

The SRQL result set can change even when SweepGroup config stays the same:
- New devices discovered that match criteria
- Device attributes change (discovery_sources, partition, tags)
- Devices deleted

**Current state:** Only SweepGroup/SweepProfile changes trigger cache invalidation.

**Solution:** Add a periodic Oban job `SweepConfigRefreshWorker` that:
1. Runs every N minutes (configurable, default 5 minutes)
2. For each tenant's enabled sweep groups:
   - Execute the SRQL query to get current target list
   - Compute hash of the result set
   - Compare with stored hash on the SweepGroup or ConfigInstance
   - If changed, invalidate the config cache and publish NATS event
3. This ensures agents receive updated configs within the refresh interval

**Alternative considered:** Adding a notifier to Device resource. Rejected because:
- High volume of device changes could cause excessive invalidations
- Bulk device imports would hammer the system
- Periodic refresh is more predictable and batches changes

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
