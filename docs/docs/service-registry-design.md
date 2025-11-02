# Service Registry Design - Extending pkg/registry

## Overview

This document proposes extending the existing `pkg/registry` package to handle **service registration** in addition to device registration. The goal is to create a unified, authoritative service discovery and registration system that tracks all pollers, agents, and checkers across the ServiceRadar deployment.

## Background

### Current State

**Device Registry (Existing):**
- Located at `pkg/registry`
- Provides `Manager` interface for processing device updates
- Handles device identity resolution, canonicalization, and persistence
- Publishes to `device_updates` stream for materialized view
- Well-tested, production-ready

**Service Tracking (Current - Implicit):**
- Services tracked via `services` stream (3-day TTL)
- No persistent registry - services disappear after TTL expires
- Agents/checkers derived from service heartbeats
- No pre-registration support
- Cannot distinguish "never existed" from "stopped reporting"

**Problem:**
Per onboarding review (docs/onboarding-review-2025.md), lack of centralized service registry creates gaps:
- No pre-registration of agents/checkers before first report
- No historical record of registered services
- Cannot track service lifecycle (pending → active → inactive)
- Difficult to implement proper service discovery

### Design Goals

1. **Unified Registry Package:** Extend `pkg/registry` to handle both devices AND services
2. **Consistent Patterns:** Mirror the device registry architecture for services
3. **Explicit Registration:** Support pre-registration via edge onboarding packages
4. **Lifecycle Tracking:** Track services from creation through activation to retirement
5. **Minimal Disruption:** Work alongside existing implicit service tracking
6. **Performance:** Batch operations, efficient lookups, caching where appropriate

---

## Architecture

### Registry Package Structure

```
pkg/registry/
├── interfaces.go           # Existing Manager interface + new ServiceManager
├── registry.go             # Device registry (existing)
├── service_registry.go     # NEW: Service registry implementation
├── service_models.go       # NEW: Service registration models
├── service_lifecycle.go    # NEW: Service lifecycle management
├── identity_resolver.go    # Existing, may extend for services
├── identity_publisher.go   # Existing, may extend for services
└── ...
```

---

## Service Registry Interface

### ServiceManager Interface

```go
package registry

import (
    "context"
    "time"

    "github.com/carverauto/serviceradar/pkg/models"
)

// ServiceManager manages the lifecycle and registration of all services
// (pollers, agents, checkers) in the ServiceRadar system.
type ServiceManager interface {
    // RegisterPoller explicitly registers a new poller.
    // Used during edge package creation, K8s ClusterSPIFFEID creation, etc.
    RegisterPoller(ctx context.Context, reg *PollerRegistration) error

    // RegisterAgent explicitly registers a new agent under a poller.
    RegisterAgent(ctx context.Context, reg *AgentRegistration) error

    // RegisterChecker explicitly registers a new checker under an agent.
    RegisterChecker(ctx context.Context, reg *CheckerRegistration) error

    // RecordHeartbeat records a service heartbeat from status reports.
    // This updates last_seen and activates pending services.
    RecordHeartbeat(ctx context.Context, heartbeat *ServiceHeartbeat) error

    // RecordBatchHeartbeats handles batch heartbeat updates efficiently.
    RecordBatchHeartbeats(ctx context.Context, heartbeats []*ServiceHeartbeat) error

    // GetPoller retrieves a poller by ID.
    GetPoller(ctx context.Context, pollerID string) (*RegisteredPoller, error)

    // GetAgent retrieves an agent by ID.
    GetAgent(ctx context.Context, agentID string) (*RegisteredAgent, error)

    // GetChecker retrieves a checker by ID.
    GetChecker(ctx context.Context, checkerID string) (*RegisteredChecker, error)

    // ListPollers retrieves all pollers matching filter.
    ListPollers(ctx context.Context, filter *ServiceFilter) ([]*RegisteredPoller, error)

    // ListAgentsByPoller retrieves all agents under a poller.
    ListAgentsByPoller(ctx context.Context, pollerID string) ([]*RegisteredAgent, error)

    // ListCheckersByAgent retrieves all checkers under an agent.
    ListCheckersByAgent(ctx context.Context, agentID string) ([]*RegisteredChecker, error)

    // UpdateServiceStatus updates the status of a service.
    UpdateServiceStatus(ctx context.Context, serviceID string, status ServiceStatus) error

    // MarkInactive marks services as inactive if they haven't reported within threshold.
    // This is typically called by a background job.
    MarkInactive(ctx context.Context, threshold time.Duration) (int, error)

    // IsKnownPoller checks if a poller is registered and active.
    // Replaces the logic currently in pkg/core/pollers.go:701
    IsKnownPoller(ctx context.Context, pollerID string) (bool, error)
}
```

---

## Data Models

### Service Registration Types

```go
package registry

import (
    "time"

    "github.com/carverauto/serviceradar/pkg/models"
)

// ServiceStatus represents the lifecycle status of a service.
type ServiceStatus string

const (
    ServiceStatusPending  ServiceStatus = "pending"  // Registered, waiting for first report
    ServiceStatusActive   ServiceStatus = "active"   // Currently reporting
    ServiceStatusInactive ServiceStatus = "inactive" // Stopped reporting
    ServiceStatusRevoked  ServiceStatus = "revoked"  // Registration revoked
)

// RegistrationSource indicates how a service was registered.
type RegistrationSource string

const (
    RegistrationSourceEdgeOnboarding RegistrationSource = "edge_onboarding"
    RegistrationSourceK8sSpiffe      RegistrationSource = "k8s_spiffe"
    RegistrationSourceConfig         RegistrationSource = "config"          // Static config file
    RegistrationSourceImplicit       RegistrationSource = "implicit"        // From heartbeat
)

// PollerRegistration represents a poller registration request.
type PollerRegistration struct {
    PollerID           string
    ComponentID        string // From edge onboarding package
    RegistrationSource RegistrationSource
    Metadata           map[string]string
    SPIFFEIdentity     string // Optional SPIFFE ID
    CreatedBy          string // Admin user ID or system
}

// AgentRegistration represents an agent registration request.
type AgentRegistration struct {
    AgentID            string
    PollerID           string // Parent poller (required)
    ComponentID        string
    RegistrationSource RegistrationSource
    Metadata           map[string]string
    SPIFFEIdentity     string
    CreatedBy          string
}

// CheckerRegistration represents a checker registration request.
type CheckerRegistration struct {
    CheckerID          string
    AgentID            string // Parent agent (required)
    PollerID           string // Grandparent poller (denormalized for queries)
    CheckerKind        string // snmp, sysmon, rperf, etc.
    ComponentID        string
    RegistrationSource RegistrationSource
    Metadata           map[string]string
    SPIFFEIdentity     string
    CreatedBy          string
}

// ServiceHeartbeat represents a service status report.
type ServiceHeartbeat struct {
    ServiceID   string
    ServiceType string // "poller", "agent", "checker"
    PollerID    string
    AgentID     string // Empty for pollers
    CheckerID   string // Empty for agents/pollers
    Timestamp   time.Time
    SourceIP    string
    Healthy     bool
    Metadata    map[string]string
}

// RegisteredPoller represents a registered poller in the system.
type RegisteredPoller struct {
    PollerID           string
    ComponentID        string
    Status             ServiceStatus
    RegistrationSource RegistrationSource
    FirstRegistered    time.Time
    FirstSeen          *time.Time // Nil if never reported
    LastSeen           *time.Time
    Metadata           map[string]string
    SPIFFEIdentity     string
    CreatedBy          string

    // Derived stats
    AgentCount   int
    CheckerCount int
}

// RegisteredAgent represents a registered agent in the system.
type RegisteredAgent struct {
    AgentID            string
    PollerID           string
    ComponentID        string
    Status             ServiceStatus
    RegistrationSource RegistrationSource
    FirstRegistered    time.Time
    FirstSeen          *time.Time
    LastSeen           *time.Time
    Metadata           map[string]string
    SPIFFEIdentity     string
    CreatedBy          string

    // Derived stats
    CheckerCount int
}

// RegisteredChecker represents a registered checker in the system.
type RegisteredChecker struct {
    CheckerID          string
    AgentID            string
    PollerID           string
    CheckerKind        string
    ComponentID        string
    Status             ServiceStatus
    RegistrationSource RegistrationSource
    FirstRegistered    time.Time
    FirstSeen          *time.Time
    LastSeen           *time.Time
    Metadata           map[string]string
    SPIFFEIdentity     string
    CreatedBy          string
}

// ServiceFilter filters service queries.
type ServiceFilter struct {
    Statuses []ServiceStatus
    Sources  []RegistrationSource
    Limit    int
    Offset   int
}
```

---

## Database Schema

### Service Registry Tables

```sql
-- Poller registry
CREATE TABLE pollers_registry (
    poller_id           string,
    component_id        string,
    status              string,
    registration_source string,
    first_registered    DateTime64(3),
    first_seen          Nullable(DateTime64(3)),
    last_seen           Nullable(DateTime64(3)),
    metadata            string,  -- JSON
    spiffe_identity     string,
    created_by          string,
    updated_at          DateTime64(3) DEFAULT now64()
) ENGINE = ReplacingMergeTree(updated_at)
PRIMARY KEY (poller_id)
ORDER BY (poller_id, updated_at)
SETTINGS index_granularity = 8192;

-- Agent registry
CREATE TABLE agents_registry (
    agent_id            string,
    poller_id           string,
    component_id        string,
    status              string,
    registration_source string,
    first_registered    DateTime64(3),
    first_seen          Nullable(DateTime64(3)),
    last_seen           Nullable(DateTime64(3)),
    metadata            string,
    spiffe_identity     string,
    created_by          string,
    updated_at          DateTime64(3) DEFAULT now64()
) ENGINE = ReplacingMergeTree(updated_at)
PRIMARY KEY (agent_id)
ORDER BY (agent_id, poller_id, updated_at)
SETTINGS index_granularity = 8192;

-- Checker registry
CREATE TABLE checkers_registry (
    checker_id          string,
    agent_id            string,
    poller_id           string,
    checker_kind        string,
    component_id        string,
    status              string,
    registration_source string,
    first_registered    DateTime64(3),
    first_seen          Nullable(DateTime64(3)),
    last_seen           Nullable(DateTime64(3)),
    metadata            string,
    spiffe_identity     string,
    created_by          string,
    updated_at          DateTime64(3) DEFAULT now64()
) ENGINE = ReplacingMergeTree(updated_at)
PRIMARY KEY (checker_id)
ORDER BY (checker_id, agent_id, poller_id, updated_at)
SETTINGS index_granularity = 8192;

-- Service registration events (audit trail)
CREATE STREAM IF NOT EXISTS service_registration_events (
    event_id            string,
    event_type          string,  -- 'registered', 'activated', 'deactivated', 'revoked'
    service_id          string,
    service_type        string,  -- 'poller', 'agent', 'checker'
    parent_id           string,  -- For agents: poller_id, for checkers: agent_id
    registration_source string,
    actor               string,  -- Who performed the action
    timestamp           DateTime64(3),
    metadata            string   -- JSON
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 86400)
ORDER BY (timestamp, service_type, service_id)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

**Design Notes:**
- **ReplacingMergeTree** for registry tables - supports updates via inserts with `updated_at`
- **No TTL on registry tables** - persistent historical record
- **Nullable first_seen/last_seen** - distinguish "never reported" from "reported once"
- **Denormalized poller_id in checkers** - easier queries, acceptable redundancy
- **Audit stream** - 90-day retention for compliance/debugging

---

## Implementation

### ServiceRegistry Struct

```go
package registry

import (
    "context"
    "sync"

    "github.com/carverauto/serviceradar/pkg/db"
    "github.com/carverauto/serviceradar/pkg/logger"
)

type ServiceRegistry struct {
    db     db.Service
    logger logger.Logger

    // Cache for IsKnownPoller() - invalidated on registration changes
    pollerCacheMu sync.RWMutex
    pollerCache   map[string]bool
    cacheExpiry   time.Time
}

func NewServiceRegistry(database db.Service, log logger.Logger) *ServiceRegistry {
    return &ServiceRegistry{
        db:          database,
        logger:      log,
        pollerCache: make(map[string]bool),
    }
}
```

### Key Methods

#### RegisterPoller

```go
func (r *ServiceRegistry) RegisterPoller(ctx context.Context, reg *PollerRegistration) error {
    now := time.Now().UTC()

    // Check if already exists
    existing, err := r.GetPoller(ctx, reg.PollerID)
    if err == nil && existing != nil {
        // Already registered - return error or update?
        return fmt.Errorf("poller %s already registered", reg.PollerID)
    }

    // Insert into pollers_registry
    query := `INSERT INTO pollers_registry (
        poller_id, component_id, status, registration_source,
        first_registered, metadata, spiffe_identity, created_by, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`

    metadataJSON, _ := json.Marshal(reg.Metadata)

    err = r.db.Exec(ctx, query,
        reg.PollerID,
        reg.ComponentID,
        ServiceStatusPending,
        reg.RegistrationSource,
        now,
        string(metadataJSON),
        reg.SPIFFEIdentity,
        reg.CreatedBy,
        now,
    )

    if err != nil {
        return fmt.Errorf("failed to register poller: %w", err)
    }

    // Emit registration event
    r.emitRegistrationEvent(ctx, "registered", "poller", reg.PollerID, "", reg.RegistrationSource, reg.CreatedBy)

    // Invalidate cache
    r.invalidatePollerCache()

    return nil
}
```

#### RecordHeartbeat

```go
func (r *ServiceRegistry) RecordHeartbeat(ctx context.Context, heartbeat *ServiceHeartbeat) error {
    now := heartbeat.Timestamp
    if now.IsZero() {
        now = time.Now().UTC()
    }

    switch heartbeat.ServiceType {
    case "poller":
        return r.recordPollerHeartbeat(ctx, heartbeat.PollerID, now, heartbeat.SourceIP)
    case "agent":
        return r.recordAgentHeartbeat(ctx, heartbeat.AgentID, heartbeat.PollerID, now, heartbeat.SourceIP)
    case "checker":
        return r.recordCheckerHeartbeat(ctx, heartbeat.CheckerID, heartbeat.AgentID, heartbeat.PollerID, now)
    default:
        return fmt.Errorf("unknown service type: %s", heartbeat.ServiceType)
    }
}

func (r *ServiceRegistry) recordPollerHeartbeat(ctx context.Context, pollerID string, timestamp time.Time, sourceIP string) error {
    // Update last_seen, activate if pending, set first_seen if null
    query := `INSERT INTO pollers_registry (
        poller_id, status, first_seen, last_seen, updated_at
    ) SELECT
        ?,
        if(status = 'pending', 'active', status) AS new_status,
        coalesce(first_seen, ?) AS new_first_seen,
        ? AS new_last_seen,
        ? AS updated_at
    FROM pollers_registry
    WHERE poller_id = ?
    LIMIT 1`

    err := r.db.Exec(ctx, query, pollerID, timestamp, timestamp, timestamp, pollerID)
    if err != nil {
        return fmt.Errorf("failed to record poller heartbeat: %w", err)
    }

    // Check if status changed to active
    poller, _ := r.GetPoller(ctx, pollerID)
    if poller != nil && poller.Status == ServiceStatusActive && poller.FirstSeen != nil && poller.FirstSeen.Equal(timestamp) {
        // First activation
        r.emitRegistrationEvent(ctx, "activated", "poller", pollerID, "", poller.RegistrationSource, "system")
    }

    return nil
}
```

#### IsKnownPoller (Replaces core logic)

```go
const pollerCacheTTL = 5 * time.Minute

func (r *ServiceRegistry) IsKnownPoller(ctx context.Context, pollerID string) (bool, error) {
    // Check cache first
    r.pollerCacheMu.RLock()
    if time.Now().Before(r.cacheExpiry) {
        known, exists := r.pollerCache[pollerID]
        r.pollerCacheMu.RUnlock()
        if exists {
            return known, nil
        }
    }
    r.pollerCacheMu.RUnlock()

    // Query database
    query := `SELECT COUNT(*) FROM pollers_registry
              WHERE poller_id = ? AND status IN ('pending', 'active')`

    var count int
    row := r.db.QueryRow(ctx, query, pollerID)
    if err := row.Scan(&count); err != nil {
        return false, fmt.Errorf("failed to check poller: %w", err)
    }

    known := count > 0

    // Update cache
    r.pollerCacheMu.Lock()
    if time.Now().After(r.cacheExpiry) {
        // Refresh entire cache
        r.refreshPollerCache(ctx)
    } else {
        r.pollerCache[pollerID] = known
    }
    r.pollerCacheMu.Unlock()

    return known, nil
}

func (r *ServiceRegistry) refreshPollerCache(ctx context.Context) {
    query := `SELECT poller_id FROM pollers_registry WHERE status IN ('pending', 'active')`
    rows, err := r.db.Query(ctx, query)
    if err != nil {
        r.logger.Warn().Err(err).Msg("Failed to refresh poller cache")
        return
    }
    defer rows.Close()

    newCache := make(map[string]bool)
    for rows.Next() {
        var pollerID string
        if err := rows.Scan(&pollerID); err != nil {
            continue
        }
        newCache[pollerID] = true
    }

    r.pollerCache = newCache
    r.cacheExpiry = time.Now().Add(pollerCacheTTL)
}
```

---

## Integration Points

### 1. Edge Onboarding Integration

**In `pkg/core/edge_onboarding.go`:**

```go
func (s *edgeOnboardingService) CreatePackage(ctx context.Context, req *models.CreateEdgeOnboardingPackageRequest) (*models.EdgeOnboardingPackage, error) {
    // ... existing package creation logic ...

    // NEW: Register service in service registry
    switch req.ComponentType {
    case models.EdgeOnboardingComponentTypePoller:
        err := s.serviceRegistry.RegisterPoller(ctx, &registry.PollerRegistration{
            PollerID:           pollerID,
            ComponentID:        pkg.ComponentID,
            RegistrationSource: registry.RegistrationSourceEdgeOnboarding,
            Metadata:           req.Metadata,
            SPIFFEIdentity:     req.DownstreamSPIFFEID,
            CreatedBy:          getUserFromContext(ctx),
        })
        if err != nil {
            return nil, fmt.Errorf("failed to register poller: %w", err)
        }
    case models.EdgeOnboardingComponentTypeAgent:
        err := s.serviceRegistry.RegisterAgent(ctx, &registry.AgentRegistration{
            AgentID:            req.ComponentID,
            PollerID:           req.ParentID,
            ComponentID:        pkg.ComponentID,
            RegistrationSource: registry.RegistrationSourceEdgeOnboarding,
            Metadata:           req.Metadata,
            CreatedBy:          getUserFromContext(ctx),
        })
        if err != nil {
            return nil, fmt.Errorf("failed to register agent: %w", err)
        }
    case models.EdgeOnboardingComponentTypeChecker:
        err := s.serviceRegistry.RegisterChecker(ctx, &registry.CheckerRegistration{
            CheckerID:          req.ComponentID,
            AgentID:            req.ParentID,
            CheckerKind:        req.CheckerKind,
            ComponentID:        pkg.ComponentID,
            RegistrationSource: registry.RegistrationSourceEdgeOnboarding,
            Metadata:           req.Metadata,
            CreatedBy:          getUserFromContext(ctx),
        })
        if err != nil {
            return nil, fmt.Errorf("failed to register checker: %w", err)
        }
    }

    return pkg, nil
}
```

### 2. Core Service Integration

**In `pkg/core/pollers.go`:**

```go
// OLD:
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

// NEW:
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

**In `pkg/core/services.go`:**

```go
func (s *Server) registerServiceDevice(ctx context.Context, /* ... */) error {
    // ... existing device registration logic ...

    // NEW: Record service heartbeat
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

    // ... rest of existing logic ...
}
```

### 3. K8s SPIFFE Controller Integration

**Add webhook to SPIRE Controller Manager:**

When `ClusterSPIFFEID` is created, call ServiceRadar API to register service:

```go
// In SPIRE controller reconciliation loop
func (r *ClusterSPIFFEIDReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // ... existing SPIRE entry creation ...

    // NEW: Register with ServiceRadar service registry
    if isServiceRadarWorkload(spiffeID) {
        err := r.serviceRadarClient.RegisterService(ctx, &RegisterServiceRequest{
            ServiceID:          extractServiceID(spiffeID),
            ServiceType:        extractServiceType(spiffeID),
            RegistrationSource: "k8s_spiffe",
            SPIFFEIdentity:     spiffeID.String(),
            Metadata:           extractMetadata(instance),
        })
        if err != nil {
            // Log but don't fail reconciliation
            logger.Error(err, "Failed to register with ServiceRadar")
        }
    }

    return ctrl.Result{}, nil
}
```

---

## Migration Plan

### Phase 1: Core Infrastructure (Week 1)
- [ ] Create `pkg/registry/service_registry.go`
- [ ] Define `ServiceManager` interface
- [ ] Implement data models
- [ ] Create database migration for registry tables
- [ ] Unit tests for ServiceRegistry

### Phase 2: Basic Integration (Week 1-2)
- [ ] Integrate with edge onboarding package creation
- [ ] Add heartbeat recording from `ReportStatus` RPC
- [ ] Replace `isKnownPoller()` to use service registry
- [ ] Integration tests

### Phase 3: API & UI (Week 2)
- [ ] Add REST API endpoints:
  - `GET /api/admin/services/pollers`
  - `GET /api/admin/services/agents`
  - `GET /api/admin/services/checkers`
  - `GET /api/admin/services/{id}`
- [ ] Add service registry dashboard to UI
- [ ] Show parent-child relationships

### Phase 4: K8s Integration (Week 3)
- [ ] Add SPIRE Controller webhook for service registration
- [ ] Register K8s services automatically on `ClusterSPIFFEID` creation
- [ ] Test with demo namespace

### Phase 5: Background Jobs (Week 3)
- [ ] Implement `MarkInactive()` background job
- [ ] Add alerting for services stuck in 'pending' state
- [ ] Add metrics collection

### Phase 6: Migration & Cleanup (Week 4)
- [ ] Backfill existing services from `services` stream
- [ ] Update all documentation
- [ ] Remove legacy poller tracking code from edge onboarding
- [ ] Performance tuning and optimization

---

## Benefits

### 1. Centralized Service Discovery
- **Single source of truth** for all services in the system
- Clear answer to "what services are registered?"
- Historical audit trail

### 2. Pre-Registration Support
- Register agents/checkers before they start reporting
- Track deployment progress (pending → active)
- Validate configuration before installation

### 3. Lifecycle Management
- Track services from creation to retirement
- Automatic activation on first heartbeat
- Detect and alert on inactive services

### 4. Consistent Patterns
- Mirror proven device registry architecture
- Reuse testing/observability patterns
- Developer familiarity

### 5. Scalability
- Caching for high-frequency queries (`IsKnownPoller`)
- Batch operations for efficiency
- Background jobs for maintenance

---

## Security Considerations

1. **Authorization:**
   - Only admins can register services explicitly
   - Heartbeats from authenticated connections only
   - Audit all registration events

2. **Data Validation:**
   - Validate parent references (agent → poller, checker → agent)
   - Prevent duplicate registrations
   - Sanitize metadata

3. **SPIFFE Integration:**
   - Store SPIFFE IDs in registry
   - Cross-reference with SPIRE server state
   - Alert on mismatches

---

## Future Enhancements

### Service Dependencies
Track dependencies between services (e.g., agent depends on poller being healthy).

### Service Mesh Integration
Export service registry to service mesh control plane.

### Auto-Decommission
Automatically revoke services that have been inactive for extended periods.

### Multi-Tenancy
Extend registry to support multi-tenant deployments with namespace isolation.

---

## Conclusion

Extending `pkg/registry` to handle service registration provides a unified, authoritative system for tracking all pollers, agents, and checkers. This design:

- ✅ Mirrors proven device registry patterns
- ✅ Solves all gaps identified in onboarding review
- ✅ Minimal disruption to existing code
- ✅ Enables rich service discovery and lifecycle management
- ✅ Foundation for future enhancements

By treating services as first-class citizens alongside devices, we create a robust foundation for scaling ServiceRadar deployments.

---

## References

- `docs/onboarding-review-2025.md` - Gap analysis
- `pkg/registry/` - Existing device registry
- GH-1909: Edge onboarding: support agents and checkers
- GH-1915 / serviceradar-57: Create common onboarding library
- GH-1891: Implement zero-touch onboarding

---

*Document created: November 1, 2025*
*Author: ServiceRadar Core Team*
*Status: Design Proposal*
