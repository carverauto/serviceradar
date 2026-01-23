# Change: Fix mapper interfaces ingestion constraint mismatch with TimescaleDB

## Why
Mapper interfaces ingestion fails with unique constraint violations because TimescaleDB hypertables use chunk-prefixed constraint names that Ash/Ecto can't match.

Error example:
```
* "1_2_discovered_interfaces_pkey" (unique_constraint)
The changeset defined the following constraints:
    * "discovered_interfaces_pkey" (unique_constraint)
```

When TimescaleDB partitions the `discovered_interfaces` hypertable into chunks, it prefixes constraint names with chunk IDs (e.g., `1_2_`, `1_3_`). Ash's bulk_create with upsert tries to match constraint names during conflict handling, but the actual constraint name doesn't match the expected `discovered_interfaces_pkey`.

GitHub Issue: #2431

## What Changes

### Option A: Use ON CONFLICT with column list (Recommended)
Modify the upsert to use `ON CONFLICT (timestamp, device_id, interface_uid) DO UPDATE` instead of relying on constraint name matching. This requires ensuring AshPostgres generates the correct SQL.

### Option B: Catch and retry with error handling
Wrap the bulk_create in error handling that catches constraint violations and filters out duplicates before retrying.

### Option C: Use raw SQL for hypertable inserts
Bypass Ash for interface inserts and use raw SQL with proper `ON CONFLICT` clause.

### Recommended: Option A with Option B fallback
- Configure Ash to use column-based conflict detection
- Add error handling to catch any remaining constraint violations and treat them as skippable duplicates

## Impact
- Affected specs: network-discovery
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex`
  - Possibly `elixir/serviceradar_core/lib/serviceradar/inventory/interface.ex` (if action changes needed)
