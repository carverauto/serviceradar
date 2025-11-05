# ServiceRadar Architecture Refactor Plan

## Executive Summary

ServiceRadar's current architecture treats Proton (a stream processing database) as the primary source of truth for device state, causing severe performance issues. This document outlines a comprehensive refactor to establish a proper layered architecture where Proton serves as an OLAP warehouse for time-series analytics, while device state lives in purpose-built caches and indexes.

---

## Retrospective: How We Got Here

### The Original Design

ServiceRadar began with a simple data flow:
1. Agents/pollers discover devices and send updates to Core
2. Core writes to `device_updates` stream in Proton
3. Materialized view (`unified_device_pipeline_mv`) aggregates updates into `unified_devices` (versioned_kv stream)
4. UI/API queries `table(unified_devices)` for device lists, stats, and inventory

This worked fine for **small deployments** (hundreds of devices), but broke down at scale.

### What Broke

As the fleet grew to **~50,000 devices**, we hit several critical issues:

1. **Proton CPU pegged at 99%** (3986m / 4 cores)
   - Every UI page load triggered full table scans
   - Stats cards issued `SELECT count(*) FROM table(unified_devices)` repeatedly
   - Device API lookups read 800k+ rows per batch

2. **Query pattern anti-patterns**
   - `LIMIT 1 BY device_id` with `WHERE ... IN (...)` caused Proton aggregate errors (Code 184)
   - UI fanned out individual queries for every device's collector status
   - No caching layer between API and database

3. **Metadata scraping for capabilities**
   - Collector capability derived by checking `metadata['_alias_last_seen_service_id']`
   - Every render required parsing map keys across entire device table
   - No authoritative source for "does device X have collector Y?"

4. **Unbounded SRQL queries**
   - Dashboard stat cards hit SRQL with live aggregations
   - Inventory search did full-text scans on metadata maps
   - No pre-aggregated views or indexes

### Why The Tactical Fix Wasn't Enough

On 2025-11-04, we implemented a **query optimization** using CTE patterns:
```sql
WITH filtered AS (SELECT * FROM table(unified_devices) WHERE ...)
SELECT * FROM filtered ORDER BY ... LIMIT 1 BY device_id
```

**Results:**
- CPU reduced from 3986m → 490-1492m (62-88% reduction)
- Fixed Code 184 aggregate errors
- Queries completed successfully

**But:** We're still fundamentally doing the wrong thing:
- Every device lookup still scans Proton's versioned_kv stream
- Stats still count the entire table on every refresh
- No separation of concerns: Proton is both OLTP and OLAP

The tactical fix bought us time, but the architecture is still backwards.

---

## Why This Needs To Get Fixed

### Performance at Scale
- **Current:** 50k devices = 490-1492m CPU baseline
- **Projected:** 100k devices = Proton becomes unusable again
- **Target:** Device state lookups should be <10ms from cache, not 500ms+ from database scans

### Operational Complexity
- **Current:** Debugging "why is this device missing?" requires SQL archaeology through metadata maps
- **Target:** First-class capability records with audit trails

### Data Modeling
- **Current:** Everything is a key-value metadata blob; relationships are implicit
- **Target:** Explicit Device ⇄ Service ⇄ Capability graph

### Cost
- **Current:** Proton pod consumes 4+ CPU cores doing repetitive lookups
- **Target:** Proton only runs analytics queries; state lookups are O(1) from memory

---

## What Needs To Get Fixed

### 1. Proton's Role Must Change
**Problem:** Proton is being used as both:
- Primary source of truth for "what devices exist right now?"
- Time-series analytics engine for "show me ICMP metrics over the last 7 days"

**Fix:** Proton should **only** be the analytics engine. Device state belongs elsewhere.

### 2. No Canonical Registry
**Problem:** There's no single source of truth for the device graph. We have:
- `unified_devices` stream (versioned_kv)
- `unified_devices_registry` stream (empty, has DELETE rules)
- Go code deriving state from metadata scraping

**Fix:** Build a **Device Registry Service** that owns the canonical device graph.

### 3. Collector Capability Is Inferred, Not Declared
**Problem:** We determine "does device X support ICMP?" by:
```go
hasCollector := metadata["_alias_last_seen_service_id"] != ""
```
This is fragile, unauditable, and requires scanning all metadata.

**Fix:** Collectors should **register** their capabilities as first-class records.

### 4. Stats Are Computed On Every Request
**Problem:** Dashboard tiles issue live queries:
```sql
SELECT count(*) FROM table(unified_devices) WHERE ...
```
This scans 50k devices every page load.

**Fix:** Pre-aggregate stats into a narrow summary table/cache, updated every N seconds.

### 5. Inventory Search Scans Everything
**Problem:** Search queries do:
```sql
SELECT * FROM table(unified_devices)
WHERE hostname LIKE '%foo%'
   OR metadata['integration_id'] LIKE '%foo%'
```
Full table scan with map key extraction.

**Fix:** Index device data in Elastic/OpenSearch or pre-compute search fields.

### 6. No Layered Data Architecture
**Problem:** Single monolithic stream serves all use cases (OLTP + OLAP).

**Fix:** Establish data lake layers:
- **Hot cache:** In-memory registry for current device state (Redis/Go map)
- **Warm index:** Search index for inventory queries (Elastic/OpenSearch)
- **Cold warehouse:** Proton for historical analytics and time-series

---

## How To Fix It

### Phase 1: Device Registry Service (Foundational)

**Goal:** Establish a canonical in-memory device graph that owns current state.

#### 1.1 Define Registry Schema
```go
// pkg/registry/device.go
type DeviceRecord struct {
    DeviceID        string
    IP              string
    PollerID        string
    AgentID         string
    Hostname        *string
    MAC             *string
    DiscoverySources []string
    IsAvailable     bool
    FirstSeen       time.Time
    LastSeen        time.Time
    DeviceType      string

    // First-class fields (no longer metadata)
    IntegrationID   *string  // from Armis/NetBox
    CollectorAgentID *string  // if this device has a collector

    // Structured capabilities
    Capabilities    []string  // ["icmp", "snmp", "sysmon"]

    Metadata        map[string]string  // only for unstructured extras
}
```

#### 1.2 Build Registry Cache
```go
// pkg/registry/cache.go
type DeviceRegistry struct {
    mu       sync.RWMutex
    devices  map[string]*DeviceRecord  // deviceID -> record
    byIP     map[string][]*DeviceRecord
    byMAC    map[string]*DeviceRecord

    // Stats cache
    stats    *StatsSnapshot
    statsAge time.Time
}

func (r *DeviceRegistry) Get(deviceID string) (*DeviceRecord, bool)
func (r *DeviceRegistry) Upsert(device *DeviceRecord)
func (r *DeviceRegistry) FindByIP(ip string) []*DeviceRecord
func (r *DeviceRegistry) GetStats() *StatsSnapshot
```

#### 1.3 Hydrate From Proton On Startup
```go
// pkg/core/registry_loader.go
func HydrateRegistryFromProton(ctx context.Context, db *db.DB, reg *registry.DeviceRegistry) error {
    // One-time bulk load
    query := `
    SELECT device_id, ip, hostname, mac, ...
    FROM table(unified_devices)
    WHERE metadata['_merged_into'] = ''
      AND metadata['_deleted'] != 'true'
    `

    devices, err := db.QueryUnifiedDevices(ctx, query)
    for _, d := range devices {
        reg.Upsert(toRegistryRecord(d))
    }
}
```

#### 1.4 Keep Registry Updated
Option A: **Subscribe to device_updates stream**
```go
// Subscribe to Proton stream
query := `SELECT * FROM device_updates`
for update := range stream {
    registry.Upsert(update)
}
```

Option B: **Write to registry directly in Core**
```go
// pkg/core/device_manager.go
func (dm *DeviceManager) UpsertDevice(device *models.UnifiedDevice) {
    // Write to Proton (for history)
    dm.db.StoreDeviceUpdate(device)

    // Update registry (for current state)
    dm.registry.Upsert(toRegistryRecord(device))
}
```

**Decision:** Use Option B for now (simpler, no stream subscription overhead).

---

### Phase 2: First-Class Collector Capabilities

**Goal:** Stop deriving collector capability from metadata. Make it explicit.

#### 2.1 Define Collector Capability Schema
```go
// pkg/models/collector.go
type CollectorCapability struct {
    DeviceID    string
    Capabilities []string  // ["icmp", "snmp", "sysmon", "netflow"]
    AgentID     string
    PollerID    string
    LastSeen    time.Time
    ServiceName string  // e.g., "k8s-agent"
}
```

#### 2.2 Store In Registry
```go
// pkg/registry/capabilities.go
type CapabilityIndex struct {
    mu          sync.RWMutex
    byDevice    map[string]*CollectorCapability
    byCapability map[string][]string  // "icmp" -> [deviceIDs]
}

func (c *CapabilityIndex) Set(deviceID string, cap *CollectorCapability)
func (c *CapabilityIndex) HasCapability(deviceID, capability string) bool
func (c *CapabilityIndex) ListDevicesWithCapability(capability string) []string
```

#### 2.3 Emit Capabilities From Agents/Pollers
When agent/poller registers or sends heartbeat:
```go
// pkg/core/edge_onboarding.go
func (e *EdgeOnboardingService) RecordActivation(ctx context.Context, req *ActivationRequest) {
    // ... existing activation logic ...

    // Register collector capability
    cap := &models.CollectorCapability{
        DeviceID:    req.DeviceID,
        Capabilities: req.Capabilities,  // new field
        AgentID:     req.AgentID,
        PollerID:    req.PollerID,
        LastSeen:    time.Now(),
        ServiceName: req.ServiceName,
    }
    e.registry.SetCapability(req.DeviceID, cap)
}
```

#### 2.4 Update API To Use Capabilities
```go
// pkg/core/api/collectors.go
func (h *Handler) GetDeviceCollectorStatus(deviceID string) bool {
    return h.registry.HasCapability(deviceID, "icmp")
}
```

**Remove:** All metadata scraping like `metadata['_alias_last_seen_service_id']`.

---

### Phase 3: Pre-Aggregated Stats (Dashboard Performance)

**Goal:** Stop issuing live `count()` queries for dashboard tiles.

#### 3.1 Define Stats Schema
```go
// pkg/registry/stats.go
type StatsSnapshot struct {
    Timestamp       time.Time
    TotalDevices    int
    DevicesWithICMP int
    DevicesWithSNMP int
    DevicesWithSysmon int
    ActiveDevices   int  // seen in last 24h

    ByPartition     map[string]*PartitionStats
}

type PartitionStats struct {
    PartitionID  string
    DeviceCount  int
    ActiveCount  int
}
```

#### 3.2 Build Stats Aggregator
```go
// pkg/core/stats_aggregator.go
type StatsAggregator struct {
    registry *registry.DeviceRegistry
    stats    *registry.StatsSnapshot
    interval time.Duration
}

func (s *StatsAggregator) Run(ctx context.Context) {
    ticker := time.NewTicker(s.interval)  // e.g., 10 seconds
    for {
        select {
        case <-ticker.C:
            s.computeStats()
        case <-ctx.Done():
            return
        }
    }
}

func (s *StatsAggregator) computeStats() {
    s.registry.mu.RLock()
    defer s.registry.mu.RUnlock()

    snapshot := &registry.StatsSnapshot{
        Timestamp: time.Now(),
    }

    for _, device := range s.registry.devices {
        snapshot.TotalDevices++
        if s.registry.HasCapability(device.DeviceID, "icmp") {
            snapshot.DevicesWithICMP++
        }
        // ... etc
    }

    s.stats = snapshot
}
```

#### 3.3 Serve Stats From Cache
```go
// pkg/core/api/stats.go
func (h *Handler) GetDeviceStats() *StatsSnapshot {
    return h.aggregator.GetStats()  // O(1), no DB query
}
```

**Result:** Dashboard stats load in <1ms from memory, not 500ms+ from Proton.

---

### Phase 3b: Critical Log Rollups (Dashboard Observability)

**Goal:** Remove Proton hot-path dependency for fatal/error log widgets.

#### 3b.1 Build Log Digest Aggregator
```go
// pkg/core/log_digest.go
type LogDigestAggregator struct {
    mu        sync.RWMutex
    critical  []models.LogSummary  // capped ring buffer of latest fatal/error logs
    counters  *models.LogCounters  // rolling 1h/24h stats
}

func (a *LogDigestAggregator) Run(ctx context.Context, tailer LogTailer) {
    for entry := range tailer.Stream(ctx, SeverityFatal, SeverityError) {
        a.append(entry)
    }
}
```

- [x] Tail Proton `logs` data via unbounded stream cursor into the aggregator
- [x] Maintain capped ring buffer (e.g. last 200 fatal/error events) plus rolling counters
- [x] Persist digests in registry cache with optional durable spill (BoltDB) for warm restarts
- [x] Investigate readiness regressions when enabling `UseLogDigest` (root cause: synchronous Proton bootstrap blocked HTTP startup; fixed by moving hydration to a timed background task so readiness succeeds before streaming starts)
- [x] Fix Proton streaming syntax error (switched tailer to native streaming `SELECT ... FROM logs`, confirmed steady feed and `/api/logs/critical` returns injected fatal records without touching Proton)
- [x] Resolve poller registry cast error (scan `COUNT(*)` into `uint64`, rolled new core image, warning gone; Proton pool tuned for higher concurrency to stop acquire timeouts)

#### 3b.2 Expose Critical Log API
```go
// pkg/core/api/logs.go
func (h *Handler) GetCriticalLogs(limit int) ([]models.LogSummary, *models.LogCounters) {
    return h.logDigest.Latest(limit), h.logDigest.Counters()
}
```

- [x] Implement `/api/logs/critical` and `/api/logs/critical/counters`
- [x] Add feature flag `UseLogDigest` defaulting to true once validated

#### 3b.3 Remove SRQL Fatal/Error Queries
- [x] Update `web/src/services/dataService.ts` `fetchAllAnalyticsData` to call new API
- [x] Refactor `CriticalLogsWidget` and Observability dashboards to consume API results
- [x] Delete or guard the legacy SRQL `in:logs severity_text:(fatal,error)` calls

**Success:** No UI component issues `SELECT * FROM table(logs)`; Proton log workload handled by single aggregator stream.

---

### Phase 4: Search Index (Inventory Performance)

**Goal:** Stop scanning `table(unified_devices)` for inventory search.

#### 4.1 Option A: Elastic/OpenSearch
**Pros:** Rich query DSL, full-text search, faceting
**Cons:** Additional infrastructure, operational overhead

```go
// pkg/search/elastic.go
type DeviceIndex struct {
    client *elasticsearch.Client
}

func (i *DeviceIndex) Index(device *registry.DeviceRecord) error {
    doc := map[string]interface{}{
        "device_id": device.DeviceID,
        "hostname":  device.Hostname,
        "ip":        device.IP,
        "mac":       device.MAC,
        "capabilities": device.Capabilities,
        "last_seen": device.LastSeen,
    }
    return i.client.Index("devices", doc)
}

func (i *DeviceIndex) Search(query string, limit int) ([]string, error) {
    // Full-text search across hostname, IP, MAC, etc.
}
```

#### 4.2 Option B: In-Memory Trigram Index (Simpler)
**Pros:** No external deps, fast, good for prefix/substring search
**Cons:** Limited to exact/prefix matching, no complex queries

```go
// pkg/search/trigram.go
type TrigramIndex struct {
    trigrams map[string][]string  // "abc" -> [deviceIDs with "abc" in hostname/IP]
}

func (t *TrigramIndex) Add(deviceID string, text string) {
    for _, trigram := range extractTrigrams(text) {
        t.trigrams[trigram] = append(t.trigrams[trigram], deviceID)
    }
}

func (t *TrigramIndex) Search(query string) []string {
    // Intersect deviceID sets for all trigrams in query
}
```

**Decision:** Start with **Option B** (in-memory trigram) for simplicity. Migrate to Elastic later if needed.

#### 4.3 Update On Device Changes
```go
// pkg/registry/cache.go
func (r *DeviceRegistry) Upsert(device *DeviceRecord) {
    r.mu.Lock()
    defer r.mu.Unlock()

    r.devices[device.DeviceID] = device

    // Update search index
    searchText := fmt.Sprintf("%s %s %s",
        device.Hostname, device.IP, device.MAC)
    r.searchIndex.Add(device.DeviceID, searchText)
}
```

#### 4.4 API Uses Search Index
```go
// pkg/core/api/devices.go
func (h *Handler) SearchDevices(query string, limit int) ([]*DeviceRecord, error) {
    deviceIDs := h.registry.Search(query)  // Fast in-memory search

    devices := make([]*DeviceRecord, 0, len(deviceIDs))
    for _, id := range deviceIDs[:min(limit, len(deviceIDs))] {
        if dev, ok := h.registry.Get(id); ok {
            devices = append(devices, dev)
        }
    }
    return devices
}
```

**Remove:** All `SELECT * FROM table(unified_devices) WHERE ... LIKE ...` queries.

---

### Phase 5: Capability Matrix (Relationship Modeling)

**Goal:** Model Device ⇄ Service ⇄ Capability as explicit relationships.

#### 5.1 Define Schema
```go
// pkg/models/capability_matrix.go
type Service struct {
    ServiceID   string  // "k8s-agent", "edge-poller-01"
    ServiceType string  // "agent", "poller"
    SPIFFEID    string
    LastSeen    time.Time
}

type DeviceCapability struct {
    DeviceID    string
    ServiceID   string
    Capability  string  // "icmp", "snmp"
    Enabled     bool
    LastChecked time.Time
    LastSuccess *time.Time
}
```

#### 5.2 Store In Proton (Audit Trail)
```sql
CREATE STREAM device_capabilities (
    device_id string,
    service_id string,
    capability string,
    enabled bool,
    last_checked DateTime64(3),
    last_success nullable(DateTime64(3))
) PRIMARY KEY (device_id, service_id, capability)
SETTINGS mode='versioned_kv';
```

#### 5.3 Cache In Registry
```go
// pkg/registry/matrix.go
type CapabilityMatrix struct {
    mu       sync.RWMutex
    devices  map[string]map[string]*models.DeviceCapability  // deviceID -> serviceID -> cap
}

func (m *CapabilityMatrix) Set(dc *models.DeviceCapability)
func (m *CapabilityMatrix) Get(deviceID, serviceID string) (*models.DeviceCapability, bool)
func (m *CapabilityMatrix) ListForDevice(deviceID string) []*models.DeviceCapability
```

#### 5.4 Update From Agent Heartbeats
```go
// When agent checks ICMP for a device
func (a *Agent) ReportICMPCheck(deviceID string, success bool) {
    cap := &models.DeviceCapability{
        DeviceID:    deviceID,
        ServiceID:   a.ServiceID,
        Capability:  "icmp",
        Enabled:     true,
        LastChecked: time.Now(),
    }
    if success {
        cap.LastSuccess = &time.Now()
    }

    a.registry.SetCapability(cap)
    a.db.StoreCapability(cap)  // Also persist to Proton
}
```

#### 5.5 Alerts Based On Matrix
```go
// pkg/alerts/capability_monitor.go
func (m *Monitor) CheckCapabilities() {
    for deviceID, caps := range m.matrix.ListAll() {
        for _, cap := range caps {
            if cap.Capability == "icmp" &&
               cap.LastSuccess != nil &&
               time.Since(*cap.LastSuccess) > 10*time.Minute {
                m.alerter.Send(fmt.Sprintf(
                    "Device %s has not had successful ICMP in 10min", deviceID))
            }
        }
    }
}
```

**Result:** Auditable, testable capability tracking with automatic alerting.

---

### Phase 6: Proton As OLAP Only

**Goal:** Redirect all state queries away from Proton. Only use Proton for analytics.

#### 6.1 Redirect Device Lookups
**Before:**
```go
func (db *DB) GetDevice(deviceID string) (*UnifiedDevice, error) {
    query := `SELECT * FROM table(unified_devices) WHERE device_id = $1`
    return db.Query(query, deviceID)
}
```

**After:**
```go
func (r *DeviceRegistry) GetDevice(deviceID string) (*DeviceRecord, error) {
    r.mu.RLock()
    defer r.mu.RUnlock()

    if device, ok := r.devices[deviceID]; ok {
        return device, nil
    }
    return nil, ErrNotFound
}
```

#### 6.2 Keep Proton For Time-Series Only
```go
// GOOD: Query Proton for historical metrics
func (db *DB) GetICMPMetrics(deviceID string, start, end time.Time) ([]*Metric, error) {
    query := `
    SELECT timestamp, rtt, packet_loss
    FROM otel_metrics
    WHERE device_id = $1
      AND timestamp BETWEEN $2 AND $3
    ORDER BY timestamp
    `
    return db.Query(query, deviceID, start, end)
}

// BAD: Query Proton for "does device exist?"
// Use registry instead!
```

#### 6.3 Update All API Handlers
```diff
 // pkg/core/api/devices.go
 func (h *Handler) GetDevice(w http.ResponseWriter, r *http.Request) {
     deviceID := mux.Vars(r)["id"]

-    device, err := h.db.GetDevice(deviceID)
+    device, err := h.registry.GetDevice(deviceID)
     if err != nil {
         http.Error(w, "Not found", 404)
         return
     }

     json.NewEncoder(w).Encode(device)
 }
```

#### 6.4 Define Clear Boundaries
| Use Case | Data Source |
|----------|-------------|
| Device exists? | Registry (in-memory) |
| Device hostname? | Registry (in-memory) |
| Device has ICMP collector? | Registry capabilities |
| Dashboard stats (total devices)? | Aggregator cache |
| Inventory search? | Search index |
| ICMP metrics last 7 days? | **Proton** (time-series) |
| Device history (who created it)? | **Proton** (audit log) |
| SRQL exploratory query? | **Proton** (analytics) |

---

## Implementation Plan

### Sprint 1: Foundation (Week 1-2)
- [ ] Implement `pkg/registry/device.go` schema
- [ ] Implement `pkg/registry/cache.go` with in-memory map
- [ ] Implement `pkg/core/registry_loader.go` to hydrate from Proton
- [ ] Update `DeviceManager.UpsertDevice()` to write to both Proton + Registry
- [ ] Add registry to Core service initialization
- [ ] Unit tests for registry operations

**Success Criteria:** Registry hydrates from Proton, stays in sync with new updates.

### Sprint 2: Collector Capabilities (Week 3-4)
- [ ] Define `CollectorCapability` schema
- [ ] Implement `pkg/registry/capabilities.go` index
- [ ] Update agent/poller registration to emit capabilities
- [ ] Update API collectors endpoint to use registry
- [ ] Remove all metadata scraping (grep for `_alias_last_seen_service_id`)
- [ ] Update UI to use new capabilities API

**Success Criteria:** Collector status comes from explicit records, not metadata.

### Sprint 3: Stats Aggregator (Week 5)
- [ ] Implement `pkg/core/stats_aggregator.go`
- [ ] Add stats cache to registry
- [ ] Create `/api/stats` endpoint
- [ ] Update dashboard tiles to call `/api/stats`
- [ ] Remove SRQL stat card queries from UI

**Success Criteria:** Dashboard loads stats in <10ms, no Proton queries.

### Sprint 4: Search Index (Week 6-7)
- [ ] Implement `pkg/search/trigram.go` in-memory index
- [ ] Integrate with `DeviceRegistry.Upsert()`
- [ ] Add `/api/devices/search?q=...` endpoint
- [ ] Update inventory UI to use search API
- [ ] Remove `SELECT ... LIKE ...` queries

**Success Criteria:** Inventory search returns in <50ms for any query.

### Sprint 5: Capability Matrix (Week 8-9)
- [ ] Define `device_capabilities` stream in Proton
- [ ] Implement `pkg/registry/matrix.go`
- [ ] Update agent heartbeats to report capability checks
- [ ] Create capability monitoring/alerting
- [ ] Dashboard shows capability status

**Success Criteria:** Can answer "when did device X last have successful ICMP?" without manual DB queries.

### Sprint 6: Proton Boundary Enforcement (Week 10)
- [ ] Audit all `db.*` calls in `pkg/core/api`
- [ ] Replace device state queries with registry lookups
- [ ] Add middleware to block non-analytics Proton queries
- [ ] Update SRQL translator/HTTP handlers to route device lookups and searches through registry/search index
- [ ] Document "when to use Proton vs registry" guidelines
- [ ] Final performance validation

**Success Criteria:** Proton CPU <200m under normal load. All state queries hit registry.

---

## Success Metrics

### Performance
- **Registry lookups:** <1ms (currently 500ms+ from Proton)
- **Dashboard stats:** <10ms (currently 500ms+ from live count())
- **Inventory search:** <50ms (currently 1-5s from table scan)
- **Proton CPU:** <200m baseline (currently 490-1492m)

### Data Quality
- **Collector capability accuracy:** 100% (explicit records vs inferred metadata)
- **Audit trail:** All capability changes logged to Proton
- **No stale data:** Registry TTL/refresh keeps cache current

### Developer Experience
- **Query clarity:** "Get device state" = `registry.Get()`, not SQL
- **Testability:** Registry is mockable, Proton queries are not
- **Debuggability:** Capability matrix shows exact state + history

---

## Rollback Plan

Each phase is independently deployable:

1. **Phase 1-2:** If registry has issues, fall back to Proton queries (perf hit but functional)
2. **Phase 3:** If stats aggregator fails, UI can still issue live queries (slow but works)
3. **Phase 4:** If search index breaks, fall back to full table scan (slow but works)
4. **Phase 5:** Capability matrix is additive; removal doesn't break existing flows
5. **Phase 6:** Final cutover only after all phases validated

**Feature flags:**
```go
const (
    UseRegistry       = true  // Phase 1
    UseCapabilityIndex = true  // Phase 2
    UseStatsCache     = true  // Phase 3
    UseSearchIndex    = true  // Phase 4
)
```

---

## Open Questions

1. **Registry persistence:** Should we persist registry snapshots to disk for faster restarts?
2. **Registry size:** At 1M devices, in-memory registry ≈ 1-2GB. Acceptable?
3. **Search sophistication:** Do we need Elastic's query DSL, or is trigram enough?
4. **Capability staleness:** How long before we mark a collector capability as "stale"?
5. **Multi-region:** How does registry sync across clusters (if applicable)?

---

## Conclusion

This refactor transforms ServiceRadar from a Proton-centric monolith into a **layered data architecture**:

- **Hot tier:** In-memory registry for current device state (μs latency)
- **Warm tier:** Search index for inventory queries (ms latency)
- **Cold tier:** Proton for time-series analytics and audit logs (s latency acceptable)

The tactical CTE fix bought us time. This plan delivers the **real fix** that scales to millions of devices while keeping Proton CPU near zero for normal operations.
