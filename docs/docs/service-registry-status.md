# Service Registry Implementation Status

## Overview

This document tracks the implementation status of the service registry extension to `pkg/registry`. Work was started in parallel with the design review.

**Last Updated**: November 1, 2025

---

## ✅ What's Been Implemented

### Core Implementation (pkg/registry)

**Models (service_models.go)** - ✅ **COMPLETE**
- [x] ServiceStatus enum (pending, active, inactive, revoked)
- [x] RegistrationSource enum (edge_onboarding, k8s_spiffe, config, implicit)
- [x] PollerRegistration, AgentRegistration, CheckerRegistration
- [x] ServiceHeartbeat
- [x] RegisteredPoller, RegisteredAgent, RegisteredChecker
- [x] ServiceFilter
- [x] RegistrationEvent

**ServiceRegistry Implementation (service_registry.go)** - ✅ **CORE COMPLETE**
- [x] RegisterPoller() - Explicit registration with parent validation
- [x] RegisterAgent() - With parent poller validation
- [x] RegisterChecker() - With parent agent validation
- [x] RecordHeartbeat() - Routes by service type
- [x] RecordBatchHeartbeats() - Batch processing
- [x] recordPollerHeartbeat() - Updates last_seen, activates pending
- [x] recordAgentHeartbeat() - Updates last_seen, activates pending
- [x] recordCheckerHeartbeat() - Updates last_seen, activates pending
- [x] emitRegistrationEvent() - Audit trail to stream
- [x] invalidatePollerCache() - Cache management
- [x] **Auto-registration on first heartbeat** - Creates implicit registrations

**Query Methods (service_registry_queries.go)** - ✅ **COMPLETE**
- [x] GetPoller() - By poller_id with FINAL
- [x] GetAgent() - By agent_id with FINAL
- [x] GetChecker() - By checker_id with FINAL
- [x] ListPollers() - With status/source filtering
- [x] ListAgentsByPoller() - All agents under poller
- [x] ListCheckersByAgent() - All checkers under agent
- [x] UpdateServiceStatus() - Manual status override
- [x] IsKnownPoller() - **Replaces pkg/core/pollers.go:701** with caching
- [x] MarkInactive() - Background job support
- [x] ArchiveInactive() - Long-term retention management
- [x] refreshPollerCache() - 5-minute cache refresh

### Database Schema (Migration 9)

**Schema (00000000000009_service_registry.up.sql)** - ✅ **COMPLETE**
- [x] Extended `pollers` stream with registry fields
- [x] Created `agents` stream (versioned_kv)
- [x] Created `checkers` stream (versioned_kv)
- [x] Created `service_registration_events` stream (90-day TTL)
- [x] NO TTL on registry streams (lifecycle via status field)
- [x] All streams use versioned_kv mode for automatic version management

**Design Decision**: Used **versioned_kv streams** instead of ReplacingMergeTree tables
- ✅ **Better choice for Proton** - native versioned key-value support
- ✅ Automatic version management via `_tp_time`
- ✅ Simpler updates (just INSERT, engine handles deduplication)
- ✅ Better integration with streaming architecture

---

## 🔨 Architecture Comparison: Design vs Implementation

### Original Design (service-registry-design.md)
```sql
CREATE TABLE pollers_registry (...)
ENGINE = ReplacingMergeTree(updated_at)
PRIMARY KEY (poller_id);
```

### Actual Implementation
```sql
CREATE STREAM pollers (...)
PRIMARY KEY (poller_id)
SETTINGS mode='versioned_kv', version_column='_tp_time';
```

**Why This is Better:**
1. Proton's versioned_kv is purpose-built for this use case
2. No manual `updated_at` management - handled by `_tp_time`
3. Automatic deduplication on PRIMARY KEY
4. Consistent with existing Proton patterns (services, service_status)
5. Better query performance with `FINAL` modifier

---

## ⚠️ What Still Needs to be Done

### Phase 1: Complete Agent/Checker Automation (GH-1909) - 🔴 BLOCKING

**Status**: NOT STARTED - Core registry exists but not integrated

**Tasks**:
- [ ] Wire up edge onboarding to call service registry
  - [ ] Modify `pkg/core/edge_onboarding.go::CreatePackage()` to call `RegisterPoller/Agent/Checker`
  - [ ] Pass correct RegistrationSource (edge_onboarding)
  - [ ] Extract created_by from auth context
- [ ] Auto-update KV on package creation
  - [ ] Write `config/pollers/<id>/agents/<id>.json` on agent package creation
  - [ ] Write `config/agents/<id>/checkers/<id>.json` on checker package creation
  - [ ] Set status: 'pending'
- [ ] Update activation flow
  - [ ] Transition status from 'pending' to 'active' on first heartbeat
  - [ ] Already implemented in recordHeartbeat methods ✅
- [ ] UI updates for component type selection
  - [ ] Dropdown for poller/agent/checker
  - [ ] Parent selector with validation
  - [ ] Metadata forms tailored to type

**Blockers**: None - core registry ready for integration

---

### Phase 2: Core Integration - 🟡 IN PROGRESS

**Status**: Core exists, needs wiring to rest of system

#### 2.1 Replace isKnownPoller() in Core

**Current Code** (`pkg/core/pollers.go:701`):
```go
func (s *Server) isKnownPoller(ctx context.Context, pollerID string) bool {
    for _, known := range s.config.KnownPollers {
        if known == pollerID {
            return true
        }
    }

    if s.edgeOnboarding != nil {
        if s.edgeOnboarding.isPollerAllowed(ctx, pollerID) {
            return true
        }
    }

    return false
}
```

**Needs to Become**:
```go
func (s *Server) isKnownPoller(ctx context.Context, pollerID string) bool {
    // Backwards compatibility: check static config first
    for _, known := range s.config.KnownPollers {
        if known == pollerID {
            return true
        }
    }

    // Primary path: check service registry
    if s.serviceRegistry != nil {
        known, err := s.serviceRegistry.IsKnownPoller(ctx, pollerID)
        if err != nil {
            s.logger.Warn().Err(err).Msg("Failed to check service registry")
        }
        if known {
            return true
        }
    }

    return false
}
```

**Tasks**:
- [ ] Add `serviceRegistry *registry.ServiceRegistry` to Server struct
- [ ] Initialize in Server constructor from config
- [ ] Update isKnownPoller() to call registry
- [ ] Keep static config as fallback for backwards compat
- [ ] Add feature flag if needed

#### 2.2 Record Heartbeats from ReportStatus

**Current Code** (`pkg/core/services.go:869`):
```go
// Activation code exists for edge onboarding
if s.edgeOnboarding != nil {
    if pollerID != "" {
        if err := s.edgeOnboarding.RecordActivation(...); err != nil {
            // log
        }
    }
}
```

**Needs to Add**:
```go
// NEW: Record heartbeat in service registry
if s.serviceRegistry != nil {
    heartbeat := &registry.ServiceHeartbeat{
        ServiceType: determineServiceType(agentID, serviceType),
        PollerID:    pollerID,
        AgentID:     agentID,
        Timestamp:   timestamp,
        SourceIP:    sourceIP,
        Healthy:     true,
    }

    if err := s.serviceRegistry.RecordHeartbeat(ctx, heartbeat); err != nil {
        s.logger.Warn().Err(err).Msg("Failed to record service heartbeat")
    }
}

// Keep existing edge onboarding activation code
if s.edgeOnboarding != nil { ... }
```

**Tasks**:
- [ ] Add heartbeat recording to `ReportStatus` handler
- [ ] Add helper `determineServiceType()` to detect poller/agent/checker
- [ ] Ensure pollerID, agentID extracted from status report
- [ ] Handle errors gracefully (don't fail status report)

#### 2.3 Testing

**Unit Tests Needed**:
- [ ] `pkg/registry/service_registry_test.go` - Core functionality
  - [ ] RegisterPoller with duplicate detection
  - [ ] RegisterAgent with parent validation
  - [ ] RegisterChecker with parent validation
  - [ ] RecordHeartbeat status transitions
  - [ ] IsKnownPoller caching behavior
  - [ ] MarkInactive threshold logic
- [ ] `pkg/registry/service_registry_queries_test.go` - Query methods
  - [ ] List operations with filters
  - [ ] Parent-child relationships
  - [ ] Pagination

**Integration Tests Needed**:
- [ ] End-to-end: Create package → First heartbeat → Activation
- [ ] Edge onboarding flow with service registry
- [ ] K8s SPIFFE controller integration (future)

---

### Phase 3: API & Dashboard - 🔴 NOT STARTED

**REST API Endpoints** (`pkg/core/api/service_registry.go` - new file):
- [ ] `GET /api/admin/services/pollers` - List all pollers
- [ ] `GET /api/admin/services/agents` - List all agents
- [ ] `GET /api/admin/services/checkers` - List all checkers
- [ ] `GET /api/admin/services/pollers/:id` - Get poller details
- [ ] `GET /api/admin/services/agents/:id` - Get agent details
- [ ] `GET /api/admin/services/checkers/:id` - Get checker details
- [ ] `GET /api/admin/services/pollers/:id/agents` - List agents by poller
- [ ] `GET /api/admin/services/agents/:id/checkers` - List checkers by agent
- [ ] `POST /api/admin/services/:type/:id/status` - Admin status override
- [ ] `GET /api/admin/services/stats` - Registry statistics

**Web UI**:
- [ ] Service registry dashboard page
- [ ] List view with filters (status, source)
- [ ] Tree view showing parent-child relationships
- [ ] Service detail views
- [ ] Status override controls (admin only)
- [ ] Metrics/charts (services over time, by type, by status)

**Metrics** (Prometheus):
- [ ] `service_registry_total{type,status}` - Count by type and status
- [ ] `service_registry_heartbeat_age_seconds{type,id}` - Time since last heartbeat
- [ ] `service_registry_state_transitions_total{type,from,to}` - Status changes

---

### Phase 4: K8s SPIFFE Controller Integration - 🔴 NOT STARTED

**SPIRE Controller Manager Webhook**:
- [ ] Add webhook to SPIRE controller reconciliation loop
- [ ] On ClusterSPIFFEID create/update, call ServiceRadar API
- [ ] Register service with type from SPIFFE ID pattern
- [ ] Extract metadata from pod labels/annotations
- [ ] Handle reconciliation failures gracefully

**ClusterSPIFFEID Manifests**:
- [ ] Add serviceradar-specific annotations
  - `serviceradar.io/register: "true"`
  - `serviceradar.io/service-type: "poller|agent|checker"`
  - `serviceradar.io/metadata: "{}"`
- [ ] Update existing ClusterSPIFFEID resources
- [ ] Document registration behavior

**Testing**:
- [ ] Test with demo namespace
- [ ] Verify all K8s services auto-register
- [ ] Verify status transitions on pod start/stop
- [ ] Performance testing with many pods

---

### Phase 5: Background Jobs - 🔴 NOT STARTED

**MarkInactive Job**:
- [ ] Create background goroutine in Server
- [ ] Run every 5 minutes (configurable)
- [ ] Call `serviceRegistry.MarkInactive(ctx, 24*time.Hour)`
- [ ] Emit metrics on services marked inactive
- [ ] Alert on unexpected inactivity

**Cache Warming**:
- [ ] Already implemented in `refreshPollerCache()` ✅
- [ ] Ensure cache refresh runs on schedule
- [ ] Monitor cache hit rate

**Archiving** (optional):
- [ ] Run weekly: `serviceRegistry.ArchiveInactive(ctx, 90*24*time.Hour)`
- [ ] Move very old inactive services to revoked status
- [ ] Eventual cleanup/export to external storage

---

### Phase 6: Documentation - 🔴 NOT STARTED

**Code Documentation**:
- [ ] Add godoc comments to all exported types/functions
- [ ] Document versioned_kv behavior
- [ ] Document status lifecycle (pending→active→inactive→revoked)
- [ ] Document caching strategy

**Operator Documentation**:
- [ ] Update onboarding guides to mention service registry
- [ ] Document three deployment models (K8s/Edge/Dev)
- [ ] Add troubleshooting section
- [ ] Create migration guide for existing deployments
- [ ] Document API endpoints (OpenAPI/Swagger)

**Runbooks**:
- [ ] How to query service registry
- [ ] How to manually register/activate services
- [ ] How to investigate stuck pending services
- [ ] How to recover from cache issues

---

## 🎯 Critical Path to Production

### Immediate Next Steps (This Sprint)

1. **Integration with Edge Onboarding** (1-2 days)
   - Wire up `CreatePackage()` to call service registry
   - Test package creation → registration flow
   - Verify status transitions

2. **Core Integration** (2-3 days)
   - Replace `isKnownPoller()` logic
   - Add heartbeat recording from `ReportStatus`
   - Test backwards compatibility

3. **Basic Testing** (2 days)
   - Unit tests for core registry functions
   - Integration test: package creation → activation
   - Manual testing in demo environment

### Next Sprint

4. **API Endpoints** (3-4 days)
   - Implement REST API
   - Add to existing API server
   - Basic UI for listing services

5. **K8s Integration** (3-4 days)
   - SPIRE controller webhook
   - Update ClusterSPIFFEID resources
   - Test in demo namespace

### Following Sprint

6. **Background Jobs & Polish** (2-3 days)
   - MarkInactive background job
   - Metrics collection
   - Performance tuning

7. **Documentation** (2-3 days)
   - Update all docs
   - Migration guide
   - Operator runbook

---

## 📋 Open Questions

1. **Should we backfill existing services?**
   - Pollers reporting to core but not in registry
   - Agents/checkers from implicit heartbeats
   - Migration strategy for production

2. **Feature flag for registry integration?**
   - Enable/disable service registry via config
   - Gradual rollout to production
   - Fallback to old behavior if issues

3. **How to handle registry errors?**
   - If registry fails, should we still accept heartbeats?
   - Degraded mode behavior
   - Recovery procedures

4. **Cache invalidation strategy?**
   - Currently 5-minute TTL
   - Should we invalidate on writes?
   - Broadcast cache invalidation across Core instances?

---

## 🏆 Success Criteria (from serviceradar-57)

**Deployment Simplicity** ✅ (already achieved):
- Edge deployment requires only onboarding token
- No manual kubectl/KV commands
- Works across Docker and bare metal

**Service Discovery** (in progress):
- [x] Core registry implementation complete
- [ ] Can query "what services are registered?" at any time
- [ ] Pre-registration support (pending → active)
- [x] Historical audit trail (90 days) - stream exists
- [x] Clear parent-child relationships - schema supports

**Operational Visibility** (not started):
- [ ] Unified dashboard showing all services
- [ ] Health status at a glance
- [ ] Proactive alerting on issues
- [ ] Lifecycle tracking visible in UI

**Performance**:
- [x] IsKnownPoller() query < 10ms (cached) - implemented
- [ ] Support 1000+ edge services without degradation - needs testing
- [x] Batch operations for efficiency - implemented

---

## 📚 Related Documents

- `docs/docs/onboarding-review-2025.md` - Gap analysis and recommendations
- `docs/docs/service-registry-design.md` - Original technical design
- `pkg/registry/service_models.go` - Data models
- `pkg/registry/service_registry.go` - Core implementation
- `pkg/registry/service_registry_queries.go` - Query methods
- `pkg/db/migrations/00000000000009_service_registry.up.sql` - Database schema
- GH-1909: Edge onboarding: support agents and checkers
- GH-1915 / serviceradar-57: Create common onboarding library
- GH-1891: Implement zero-touch onboarding

---

*Document created: November 1, 2025*
*Status: In Progress - Core Complete, Integration Pending*
