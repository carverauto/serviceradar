## Context

Currently, BGP routing data (AS paths, communities) is stored directly in `netflow_metrics` table columns and queried by NetFlow-specific code (`NetflowBGPStats`, `NetflowLive.Visualize`). This creates tight coupling between NetFlow collection and BGP analysis, preventing other protocols (sFlow, direct BGP peering) from contributing routing information.

Existing implementation has 10 test NetFlow records with BGP data in `platform.netflow_metrics` (as_path, bgp_communities columns). The UI currently works but is embedded in the NetFlow observability tab.

**Constraints:**
- Must support TimescaleDB for time-series BGP observations
- PostgreSQL GIN indexes required for efficient AS path and community queries
- Follow ServiceRadar's platform schema isolation model (per-deployment schemas)
- Use Ash Framework for domain modeling and SystemActor for authorization
- Existing NetFlow BGP data must be migrated without data loss

## Goals / Non-Goals

**Goals:**
- Protocol-agnostic BGP data model supporting NetFlow, sFlow, BGP peering as sources
- Dedicated "BGP Routing" observability tab separate from protocol-specific views
- Efficient querying of AS topology, path diversity, and community statistics across all sources
- Preserve existing NetFlow BGP functionality during migration
- Enable future BGP collectors to reuse common infrastructure

**Non-Goals:**
- Real-time BGP session monitoring (out of scope - focus is on flow/peering-derived data)
- BGP route validation or policy enforcement (observability only)
- Historical AS path change tracking (future enhancement, not required for v1)
- Cross-deployment BGP correlation (follows platform isolation model)

## Decisions

### 1. Table Structure: Observation-based Model

**Decision:** Create `bgp_routing_info` table storing one observation per unique (timestamp, source_protocol, as_path, communities, src_endpoint, dst_endpoint) combination.

**Rationale:**
- **Deduplication**: Many flows share the same AS path. Normalizing avoids storing identical arrays millions of times.
- **Multi-protocol**: `source_protocol` ENUM ('netflow', 'sflow', 'bgp_peering') allows querying by source.
- **Aggregation-friendly**: Queries like "traffic by AS" JOIN flows to observations, SUM bytes on observation side.

**Alternatives Considered:**
- **Keep BGP in flow tables**: Rejected - duplicates data across protocols, prevents unified BGP view.
- **Fully normalized (separate as_path_observations table)**: Over-engineered for v1, adds JOIN complexity without clear benefit.

### 2. Reference Direction: Flows → BGP Observations

**Decision:** Flow tables (`netflow_metrics`, future `sflow_metrics`) have `bgp_observation_id` UUID FK to `bgp_routing_info`.

**Rationale:**
- **Many-to-one**: Thousands of flows can share one BGP observation (e.g., all traffic through AS 64512 → 64513).
- **Optional BGP**: Not all flows have BGP data. Nullable FK keeps flow tables simple.
- **Efficient JOINs**: "Get flows for AS 64513" → filter BGP observations WHERE as_path @> ARRAY[64513], JOIN to flows on observation_id.

**Alternatives Considered:**
- **BGP → Flows (one-to-many)**: Rejected - requires array of flow IDs or separate junction table, complicates queries.

### 3. Schema: TimescaleDB Hypertable with GIN Indexes

**Decision:**
```sql
CREATE TABLE platform.bgp_routing_info (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  timestamp TIMESTAMPTZ NOT NULL,
  source_protocol TEXT NOT NULL,  -- 'netflow', 'sflow', 'bgp_peering'
  as_path INTEGER[] NOT NULL,
  bgp_communities INTEGER[],
  src_ip INET,
  dst_ip INET,
  total_bytes BIGINT DEFAULT 0,
  total_packets BIGINT DEFAULT 0,
  flow_count INTEGER DEFAULT 0,
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

SELECT create_hypertable('platform.bgp_routing_info', 'timestamp');
CREATE INDEX idx_bgp_routing_as_path ON platform.bgp_routing_info USING GIN (as_path);
CREATE INDEX idx_bgp_routing_communities ON platform.bgp_routing_info USING GIN (bgp_communities);
CREATE INDEX idx_bgp_routing_source ON platform.bgp_routing_info (source_protocol, timestamp DESC);
```

**Rationale:**
- **Hypertable**: Time-series partitioning for efficient retention policies (keep BGP data longer than raw flows).
- **GIN indexes**: Fast `@>` (contains) and `&&` (overlaps) queries on AS path and community arrays.
- **Aggregation columns**: `total_bytes`, `total_packets`, `flow_count` updated when flows reference this observation (trade-off: write overhead for read performance).

**Alternatives Considered:**
- **No aggregation columns, always JOIN to flows**: Rejected - "traffic by AS" would require full table scan of flows every query.
- **Separate topology table**: Over-designed for v1, adds complexity without clear benefit yet.

### 4. UI Architecture: New BGPLive.Index LiveView

**Decision:** Create standalone `ServiceRadarWebNGWeb.BGPLive.Index` LiveView for the BGP Routing tab, not embedded in NetflowLive.

**Rationale:**
- **Separation of concerns**: BGP topology is distinct from flow analysis. Dedicated LiveView keeps code focused.
- **Independent evolution**: BGP UI can add features (historical topology, AS path comparison) without modifying NetFlow code.
- **Reusable components**: Extract `BGPLive.Components.ASTopology`, etc. that could be embedded elsewhere if needed.

**Alternatives Considered:**
- **Shared LiveView with protocol tabs**: Rejected - creates coupling, hard to navigate code.
- **Static AS topology page**: Rejected - real-time updates valuable for operational awareness.

### 5. Data Ingestion: Write Observation, Then Flow

**Decision:** NetFlow processor flow:
1. Extract BGP data (as_path, communities) from flow record
2. Upsert `bgp_routing_info` (ON CONFLICT UPDATE aggregations)
3. Get observation ID
4. Write `netflow_metrics` row with `bgp_observation_id` FK

**Rationale:**
- **Idempotency**: ON CONFLICT ensures same AS path creates one observation even if seen in multiple flows.
- **Atomic**: Single transaction writes both observation and flow, maintains referential integrity.
- **Performance**: Batch upserts possible - group flows by (as_path, communities), upsert observations once, write all flows.

**Alternatives Considered:**
- **Background job**: Rejected - adds latency, complicates error handling.
- **Separate BGP processor**: Over-engineered for v1, adds pipeline complexity.

## Risks / Trade-offs

**[Risk]** Observation table grows large if every unique (src_ip, dst_ip, as_path, communities) combination creates a row.
**→ Mitigation:** TimescaleDB compression on older chunks. Future: aggregate by (as_path, communities) only, drop endpoint granularity.

**[Risk]** Migrating existing NetFlow BGP data requires downtime or complex dual-write.
**→ Mitigation:** Two-phase migration (see below). New columns added first, old columns deprecated but not dropped until verified.

**[Risk]** Aggregation columns (total_bytes, etc.) can drift if flow updates don't propagate.
**→ Mitigation:** Flows are immutable in this system (append-only). If needed, periodic reconciliation job can SUM flows grouped by observation_id and UPDATE observations.

**[Risk]** UI shows stale data if BGP observations aren't updated in real-time.
**→ Mitigation:** Phoenix PubSub notifications when observations change, LiveView subscribes to "bgp:observations" topic.

**[Trade-off]** Storing source_protocol and endpoints in observations duplicates some data vs fully normalized model.
**→ Accepted:** Simpler queries and schema worth the storage cost. TimescaleDB compression mitigates.

## Migration Plan

### Phase 1: Additive (No Breaking Changes)
1. Create `bgp_routing_info` table and indexes (migration)
2. Add `bgp_observation_id` UUID column to `netflow_metrics` (nullable)
3. Deploy NetFlow processor change: write to BOTH old columns AND new table
4. Backfill: Generate `bgp_routing_info` rows from existing `netflow_metrics`, populate `bgp_observation_id` FKs
5. Verify: All new flows have `bgp_observation_id`, queries return same results from old and new schema

### Phase 2: Cutover
1. Deploy new BGP UI (reads from `bgp_routing_info`)
2. Update NetFlow UI to link to BGP tab instead of showing inline BGP stats
3. Monitor: Ensure BGP tab shows expected data
4. Deprecate old columns: Mark `netflow_metrics.as_path` and `bgp_communities` for future removal (keep for rollback)

### Phase 3: Cleanup (30 days later)
1. Drop deprecated columns from `netflow_metrics`
2. Archive migration code

### Rollback Strategy
- Phase 1: No-op rollback, old columns still populated
- Phase 2: Revert UI deployment, old NetFlow tab still functional
- Phase 3: Cannot rollback after column drop (wait 30 days to ensure stability)

## Open Questions

1. **AS Name Resolution**: Should `bgp_routing_info` include AS organization names (e.g., "Google") or just numbers?
   - **Option A**: Add `as_names JSONB` column mapping AS number → name (requires external dataset)
   - **Option B**: Resolve names in UI via client-side lookup (lighter backend, stale data risk)
   - **Decision needed before spec completion**

2. **Community Decoding**: Should we decode well-known communities (NO_EXPORT, NO_ADVERTISE) server-side or client-side?
   - **Recommendation**: Server-side in `BGPStats` module for consistency

3. **Retention Policy**: How long to keep BGP observations vs flows?
   - **Recommendation**: Flows 30 days, BGP observations 90 days (valuable for historical topology analysis)
   - **Needs confirmation with infrastructure team**
