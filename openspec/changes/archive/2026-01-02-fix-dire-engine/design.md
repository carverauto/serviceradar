## Context

The Device Identity and Reconciliation Engine (DIRE) has accumulated four overlapping identity resolution systems over multiple fix attempts. Each partial fix has introduced new edge cases, resulting in a system where ~10k devices out of 50k are lost due to incorrect merges, tombstone cascades, and soft-delete failures.

**Stakeholders**: Core team, demo environment, any production deployments using Armis/NetBox sync integrations.

**Constraints**:
- Must maintain backward compatibility with existing `sr:` device IDs
- Must not lose device history during migration
- Must handle 50k+ devices with sub-second batch processing
- Schema changes are acceptable if they fix fundamental issues (the current schema is broken)

## Goals / Non-Goals

**Goals**:
- Single source of truth for device identity resolution
- Strong identifiers (Armis ID, MAC, NetBox ID) are authoritative, IP is mutable attribute
- Zero device loss from IP churn
- Observable and auditable identity decisions
- Stable 50k device inventory through churn cycles

**Non-Goals**:
- Changing the sr: UUID format
- Full event sourcing / CQRS rewrite
- Rust rewrite of DIRE
- Breaking API changes to device endpoints
- Automatic repair of historical data (manual migration step)

## Decisions

### Decision 1: Unified IdentityEngine

**What**: Consolidate `DeviceIdentityResolver`, `identityResolver`, `cnpgIdentityResolver`, and `lookupCanonicalFromMaps()` into a single `IdentityEngine` struct.

**Why**: Multiple resolvers with different behaviors cause race conditions and inconsistent results. A single owner with clear precedence rules eliminates ambiguity.

**Precedence Order**:
```
1. Strong identifiers (armis_device_id > integration_id > netbox_device_id > mac)
   -> Hash to deterministic sr: UUID
2. Existing sr: UUID in update
   -> Preserve as-is
3. IP-only (no strong identifier)
   -> Lookup existing device by IP, or generate new sr: UUID
```

**Alternatives Considered**:
- Keep multiple resolvers with coordination layer: Rejected, adds complexity without solving root cause
- Remove all resolution, use source IDs directly: Rejected, breaks sr: UUID contract

### Decision 2: Strong Identifier Index Table

**What**: New `device_identifiers` table with schema:
```sql
CREATE TABLE device_identifiers (
    id SERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES unified_devices(device_id) ON DELETE CASCADE,
    identifier_type TEXT NOT NULL,  -- 'armis_device_id', 'mac', 'netbox_device_id', etc.
    identifier_value TEXT NOT NULL,
    partition TEXT NOT NULL DEFAULT 'default',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (identifier_type, identifier_value, partition)
);
CREATE INDEX idx_device_identifiers_device ON device_identifiers(device_id);
```

**Why**: Enables O(1) lookup by any strong identifier. The unique constraint prevents duplicate devices for the same strong ID (the root cause of inventory inflation).

**Approach**: Scorched earth. Drop the database, create clean schema, start fresh. No migrations, no backfills, no archaeological artifacts.

### Decision 3: IP as Mutable Attribute, Not Identity

**What**: Remove `idx_unified_devices_ip_unique_active` entirely. IP is just a column that gets updated.

**Why**: IP is a transient attribute in DHCP environments. Strong identifier uniqueness is what matters.

**New Behavior**:
```
Device update arrives:
1. Look up device_id by strong identifier in device_identifiers table
2. If found: UPDATE unified_devices SET ip = $new_ip WHERE device_id = $found_id
3. If not found: INSERT new device + INSERT into device_identifiers
```

That's it. No conflicts, no tombstones, no soft deletes.

### Decision 4: No Tombstones, No Soft Deletes

**What**: Remove the entire `_merged_into` and `_deleted` system.

**Why**: These were workarounds for a broken design. With strong ID uniqueness:
- Duplicates are impossible (DB constraint)
- IP changes are just UPDATEs
- Explicit user deletion is a hard DELETE with audit log to `device_updates` hypertable

### Decision 5: CNPG-Authoritative Reads

**What**: The in-memory `DeviceRegistry` becomes a cache, not the source of truth. CNPG is authoritative.

**Why**: Current architecture has the registry diverging from CNPG by 2-5k devices. Writes go to both, but reads from registry can return stale/incorrect data.

**Implementation**:
- `SyncRegistryFromCNPG()` on startup and every 5m (configurable)
- Registry used for hot-path reads (search, list)
- CNPG used for authoritative counts and identity lookups
- Metric tracks drift between registry and CNPG

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Data loss from dropping database | No production users yet; demo data regenerates from faker |
| Performance regression from identifier lookups | Indexed table, batch queries |
| Breaking changes to API | No API changes, only internal resolution logic |

## Migration Plan

**Scorched earth approach** - consolidate 19 migration files into one idempotent schema, no backward compatibility layers.

### Steps
1. Consolidate all migrations in `pkg/db/cnpg/migrations/` into single idempotent schema
2. Remove IP uniqueness constraint, add `device_identifiers` table
3. Implement IdentityEngine
4. Delete all the old resolver code
5. Delete all tombstone/soft-delete code
6. Delete the 19 old migration files
7. Deploy to demo with fresh database
8. Run faker
9. Verify 50k devices
10. Done

### Schema Consolidation
The current 19 migrations are archaeological layers of fixes on top of fixes. Consolidate into:
- `00000000000001_schema.up.sql` - all tables, indexes, functions in one idempotent file
- Everything uses `IF NOT EXISTS` / `IF EXISTS` for idempotency

### Rollback
- Git revert if needed
- But really, this is a clean break

## Open Questions

1. **What about devices without strong identifiers (IP-only)?**
   - Recommendation: Generate sr: UUID from hash of (partition, ip) as fallback. These devices may duplicate if IP changes, but that's acceptable for weak-identity devices.

2. **What happens to the sightings system from add-identity-reconciliation-engine?**
   - The sightings concept (weak-ID observations waiting for promotion) may still be useful. Evaluate after core DIRE fix is working.
