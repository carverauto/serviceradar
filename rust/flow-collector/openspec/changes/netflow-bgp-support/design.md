## Context

ServiceRadar's NetFlow collection architecture currently has two data flows:

1. **OCSF Normalized Flow**: Rust collector → NATS (`flows.raw.netflow`) → Zen ETL (Go) → NATS (`flows.ocsf.network_activity`) → EventWriter → `ocsf_network_activity` table
2. **Raw Metrics Flow** (this design): Rust collector → NATS (`flows.raw.netflow`) → EventWriter → `netflow_metrics` table

The OCSF flow transforms NetFlow into a security-focused schema but discards BGP metadata needed for network analysis. The original plan used a separate Go zen-consumer service, but this adds operational complexity (build, deploy, maintain).

**Current State:**
- Rust netflow-collector publishes FlowMessage protobuf to `flows.raw.netflow` NATS subject
- FlowMessage already contains BGP fields: `as_path` (repeated uint32), `bgp_communities` (repeated uint32)
- EventWriter (Elixir) uses Broadway pattern to consume from NATS JetStream
- No Elixir consumer exists for raw metrics flow (OCSF flow uses separate zen ETL)

**Constraints:**
- Must not break existing OCSF normalized flow
- Must integrate with existing EventWriter infrastructure (Broadway, GenStage)
- Must support multi-tenant partitioning (search_path determines schema)
- Database must support fast AS path containment queries (e.g., "find flows traversing AS 64512")

## Goals / Non-Goals

**Goals:**
- Consume raw NetFlow protobuf messages from NATS using EventWriter Broadway pattern
- Store NetFlow metrics with BGP routing information in dedicated `netflow_metrics` table
- Enable efficient AS path and BGP community filtering queries via GIN indexes
- Eliminate dependency on separate Go zen-consumer service (architectural simplification)
- Provide UI with BGP routing visibility (AS paths, communities, topology graphs)

**Non-Goals:**
- Modifying or replacing the OCSF normalized flow (remains separate for security use cases)
- Supporting multi-deployment routing (instance isolation model applies)
- Real-time BGP route change notifications (passive observation only)
- Enrichment with external BGP route registries (future enhancement)

## Decisions

### Decision 1: Use EventWriter Broadway Pattern Instead of Separate Go Service

**Chosen Approach:** Implement NetFlow metrics consumption as an Elixir processor within EventWriter using the existing Broadway/GenStage pattern.

**Rationale:**
- **Consolidation**: Eliminates need to build, deploy, and maintain a separate Go service (zen-consumer)
- **Proven Pattern**: EventWriter.Producer already consumes from NATS JetStream with demand-based backpressure
- **Operational Simplicity**: One fewer container to run, monitor, and troubleshoot
- **Code Reuse**: Leverage existing NATS connection management, retry logic, and batching

**Alternatives Considered:**
- **Separate Go zen-consumer** (original plan): Adds deployment complexity, requires separate NATS connection, duplicates retry/batching logic
- **Standalone Elixir GenServer**: Reinvents Broadway pattern, loses batching optimizations

**Trade-offs:**
- EventWriter becomes responsible for two data flows (OCSF via zen ETL + raw metrics direct)
- If EventWriter crashes, both flows are interrupted (acceptable - supervisor restarts)

---

### Decision 2: Create Separate NetFlowMetrics Processor

**Chosen Approach:** Create `NetFlowMetrics` processor that writes to `netflow_metrics` table, separate from existing `NetFlow` processor that writes to `ocsf_network_activity`.

**Rationale:**
- **Different Purposes**: OCSF normalized (security, compliance) vs raw metrics (network analysis, BGP visibility)
- **Different Schemas**: OCSF has class_uid, activity_id, etc.; raw metrics has BGP-specific fields
- **Independent Evolution**: Network analysis features don't impact security flow

**Alternatives Considered:**
- **Extend existing NetFlow processor**: Conflates two data flows, makes code harder to understand
- **Single table with both schemas**: Schema bloat, confusing column purposes

**Trade-offs:**
- Two processors to maintain (acceptable - clear separation of concerns)
- Duplicate decoding of FlowMessage (negligible performance impact)

---

### Decision 3: Store AS Path as INTEGER[] Array with GIN Index

**Chosen Approach:** Use PostgreSQL `INTEGER[]` array type for `as_path` column with GIN index for containment queries.

**Rationale:**
- **Fast Containment Queries**: `WHERE as_path @> ARRAY[64512]` uses GIN index for sub-second lookup
- **Type Safety**: Array enforces integer AS numbers
- **Native Operations**: PostgreSQL array functions (`unnest()`, `array_length()`) for aggregations
- **Space Efficiency**: Integer arrays are compact compared to JSONB

**Alternatives Considered:**
- **JSONB array**: Slower containment queries, less type safety
- **Comma-separated string**: No indexing, cumbersome queries
- **Separate as_path table**: Over-normalization for simple array queries

**Implementation Details:**
- Protobuf gives `uint32`, PostgreSQL INTEGER is `int32` → cap values at 2,147,483,647
- Valid for all public AS numbers (max 4,294,967,295 uint32, but real AS numbers < 4.3B)
- GIN index: `CREATE INDEX idx_netflow_metrics_as_path ON netflow_metrics USING GIN (as_path);`

---

### Decision 4: Store BGP Communities as INTEGER[] Array with GIN Index

**Chosen Approach:** Use PostgreSQL `INTEGER[]` array type for `bgp_communities` column with GIN index.

**Rationale:**
- Same benefits as AS path (fast containment, type safety, native operations)
- BGP communities are 32-bit values, fit in PostgreSQL INTEGER with same capping strategy
- UI can convert to ASN:value notation (upper 16 bits:lower 16 bits) for display

**Alternatives Considered:**
- **String array with "65000:100" format**: Harder to query numerically
- **BIGINT array**: Wastes 4 bytes per value (communities are 32-bit)

---

### Decision 5: Use Postgrex.INET Type for IP Addresses

**Chosen Approach:** Convert binary IP addresses from FlowMessage to `%Postgrex.INET{}` structs for PostgreSQL INET column type.

**Rationale:**
- **Network Operations**: Supports CIDR queries (e.g., `WHERE src_ip << '10.0.0.0/8'`)
- **IPv4 and IPv6 Support**: Single type handles both address families
- **Native Type**: PostgreSQL optimizations for IP address operations

**Alternatives Considered:**
- **String format (e.g., "10.1.0.100")**: No CIDR support, slower queries
- **Binary storage**: Requires custom conversion for queries

**Implementation Details:**
- FlowMessage `src_addr`/`dst_addr` are `bytes` (4 for IPv4, 16 for IPv6)
- Convert to `Postgrex.INET{address: {a, b, c, d}, netmask: 32}` for IPv4
- Convert to `Postgrex.INET{address: {a, b, c, d, e, f, g, h}, netmask: 128}` for IPv6

---

### Decision 6: Store Unmapped Fields in JSONB Metadata Column

**Chosen Approach:** Collect unmapped FlowMessage fields (interface numbers, VLAN IDs, sampling rate, etc.) into a `metadata` JSONB column.

**Rationale:**
- **Extensibility**: Add new fields to FlowMessage without schema migrations
- **Avoid Column Bloat**: ~40 FlowMessage fields, only ~10 need dedicated columns
- **Flexible Queries**: JSONB supports queries like `WHERE metadata->>'vlan_id' = '100'`

**Alternatives Considered:**
- **Add column for every field**: Table bloat, many NULL values
- **Ignore unmapped fields**: Lose potentially useful debugging data

**Trade-offs:**
- JSONB queries slower than indexed columns (acceptable for occasional metadata queries)
- No schema validation on metadata content (acceptable for non-critical fields)

---

### Decision 7: Route flows.raw.netflow to netflow_raw Batcher

**Chosen Approach:** Add routing rule in `Pipeline.ex` to route `flows.raw.netflow` subject to `:netflow_raw` batcher.

**Rationale:**
- **Subject-Based Routing**: EventWriter already uses subject prefixes to route messages
- **Dedicated Batching**: NetFlow metrics have different batch characteristics (batch_size=50, batch_timeout=500ms) than OCSF events
- **Parallel Processing**: netflow_raw batcher processes independently from other streams

**Implementation Details:**
```elixir
defp batcher_rules do
  [
    # ... existing rules ...
    {:netflow_raw, &String.starts_with?(&1, "flows.raw.netflow")},
    {:netflow, &String.starts_with?(&1, "netflow.")}  # OCSF normalized
  ]
end

defp get_processor(:netflow_raw), do: ServiceRadar.EventWriter.Processors.NetFlowMetrics
defp get_processor(:netflow), do: ServiceRadar.EventWriter.Processors.NetFlow  # existing OCSF
```

## Risks / Trade-offs

### Risk: Protobuf Decoding Failures

**Risk:** Malformed protobuf messages from NATS cause processor crashes or data loss.

**Mitigation:**
- Wrap `FlowMessage.decode/1` in try/rescue
- Log decode failures at debug level (not error to avoid noise)
- NACK failed messages for retry
- Return `nil` from `parse_message/1` to skip failed records
- Empty batch handling (`{:ok, 0}` when all messages fail to decode)

---

### Risk: uint32 to int32 Overflow

**Risk:** AS numbers or BGP community values exceed 2,147,483,647 (max int32).

**Mitigation:**
- Cap values at 2,147,483,647 via `min(value, 2_147_483_647)`
- Real-world: Public AS numbers max at ~4.3B (uint32), but capping is safe
- BGP communities are 32-bit, well within range after capping
- Document this limitation in processor comments

**Trade-off:** Theoretical data loss if values exceed int32 max (unlikely in practice)

---

### Risk: GIN Index Performance on Large Arrays

**Risk:** AS paths with 20+ hops may degrade GIN index performance.

**Mitigation:**
- Real-world AS paths rarely exceed 10 hops (most are 2-5)
- GIN indexes are optimized for array operations
- Monitor query performance and adjust batch sizes if needed

**Trade-off:** Long AS paths (rare) may be slower to query

---

### Risk: EventWriter Becomes Single Point of Failure

**Risk:** If EventWriter crashes, both OCSF and raw metrics flows are interrupted.

**Mitigation:**
- Elixir supervisor restarts EventWriter automatically
- NATS JetStream retains messages during downtime (no data loss)
- Consumer resumes from last ack'd message after restart
- Monitor EventWriter health via telemetry

**Trade-off:** Both flows share fate (acceptable for operational simplicity)

---

### Risk: Database Schema Isolation

**Risk:** Multi-tenant deployments must isolate `netflow_metrics` table by schema.

**Mitigation:**
- PostgreSQL `search_path` determines schema (set by CNPG credentials)
- EventWriter uses `ServiceRadar.Repo` which inherits search_path
- Each deployment writes to its own schema's `netflow_metrics` table
- No cross-deployment queries possible at instance level

**Trade-off:** None - follows existing instance isolation model

## Migration Plan

### Deployment Steps

1. **Database Migration**:
   - Run migration to create `netflow_metrics` hypertable with GIN indexes
   - Migration includes: timestamp column, INET columns, INTEGER[] arrays, JSONB metadata
   - Create indexes: GIN on `as_path`, GIN on `bgp_communities`, BTREE on `timestamp`

2. **Deploy Elixir Code**:
   - Deploy core-elx with new NetFlowMetrics processor
   - Update EventWriter config to subscribe to `flows.raw.netflow` subject
   - Pipeline routing automatically directs messages to new processor

3. **Verify Data Flow**:
   - Check NATS consumer connects to `flows.raw.netflow` stream
   - Verify rows appear in `netflow_metrics` table
   - Confirm BGP fields populated (AS path, communities)
   - Monitor telemetry for batch processing metrics

4. **Remove zen-consumer** (optional):
   - If zen-consumer was used for raw metrics, remove from deployment
   - Update docker-compose or k8s manifests to exclude zen-consumer container

### Rollback Strategy

- **If EventWriter fails to start**: Revert code deploy, EventWriter falls back to previous behavior
- **If database migration fails**: Rollback migration, core-elx continues without netflow_metrics
- **Data loss**: None - NATS JetStream retains messages until consumer acks

### Testing Plan

1. **Unit Tests**:
   - Test `NetFlowMetrics.parse_message/1` with valid/invalid protobuf
   - Test IP address conversion (IPv4, IPv6, invalid lengths)
   - Test AS path/community extraction (empty, single, multiple values)
   - Test uint32 → int32 capping logic

2. **Integration Tests**:
   - Send FlowMessage protobuf to NATS `flows.raw.netflow` subject
   - Verify rows inserted into `netflow_metrics` table
   - Verify BGP fields correctly populated
   - Test GIN index queries (`WHERE as_path @> ARRAY[...]`)

3. **Load Testing**:
   - Send 10,000 flows/second from netflow_generator
   - Verify batch processing keeps up (target: < 1 second batch latency)
   - Monitor database write throughput and EventWriter backpressure

## Open Questions

**None** - All technical decisions are resolved. Implementation is ready to proceed.
