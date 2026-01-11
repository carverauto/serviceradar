# Service Registry Design - Extending pkg/registry

## Overview

This document proposes extending the existing `pkg/registry` package to handle **service registration** in addition to device registration. The goal is to create a unified, authoritative service discovery and registration system that tracks all gateways, agents, and checkers across the ServiceRadar deployment.

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
// (gateways, agents, checkers) in the ServiceRadar system.
type ServiceManager interface {
    // RegisterGateway explicitly registers a new gateway.
    // Used during edge package creation, K8s ClusterSPIFFEID creation, etc.
    RegisterGateway(ctx context.Context, reg *GatewayRegistration) error

    // RegisterAgent explicitly registers a new agent under a gateway.
    RegisterAgent(ctx context.Context, reg *AgentRegistration) error

    // RegisterChecker explicitly registers a new checker under an agent.
    RegisterChecker(ctx context.Context, reg *CheckerRegistration) error

    // RecordHeartbeat records a service heartbeat from status reports.
    // This updates last_seen and activates pending services.
    RecordHeartbeat(ctx context.Context, heartbeat *ServiceHeartbeat) error

    // RecordBatchHeartbeats handles batch heartbeat updates efficiently.
    RecordBatchHeartbeats(ctx context.Context, heartbeats []*ServiceHeartbeat) error

    // GetGateway retrieves a gateway by ID.
    GetGateway(ctx context.Context, gatewayID string) (*RegisteredGateway, error)

    // GetAgent retrieves an agent by ID.
    GetAgent(ctx context.Context, agentID string) (*RegisteredAgent, error)

    // GetChecker retrieves a checker by ID.
    GetChecker(ctx context.Context, checkerID string) (*RegisteredChecker, error)

    // ListGateways retrieves all gateways matching filter.
    ListGateways(ctx context.Context, filter *ServiceFilter) ([]*RegisteredGateway, error)

    // ListAgentsByGateway retrieves all agents under a gateway.
    ListAgentsByGateway(ctx context.Context, gatewayID string) ([]*RegisteredAgent, error)

    // ListCheckersByAgent retrieves all checkers under an agent.
    ListCheckersByAgent(ctx context.Context, agentID string) ([]*RegisteredChecker, error)

    // UpdateServiceStatus updates the status of a service.
    UpdateServiceStatus(ctx context.Context, serviceID string, status ServiceStatus) error

    // MarkInactive marks services as inactive if they haven't reported within threshold.
    // This is typically called by a background job.
    MarkInactive(ctx context.Context, threshold time.Duration) (int, error)

    // DeleteService permanently deletes a service from the registry.
    // This should only be called for services that are no longer needed (status: revoked or inactive).
    // Returns error if service is still active.
    DeleteService(ctx context.Context, serviceType, serviceID string) error

    // PurgeInactive permanently deletes services that have been inactive or revoked
    // for longer than the retention period. This is typically called by a background job.
    PurgeInactive(ctx context.Context, retentionPeriod time.Duration) (int, error)

    // IsKnownGateway checks if a gateway is registered and active.
    // Replaces the logic currently in pkg/core/gateways.go:701
    IsKnownGateway(ctx context.Context, gatewayID string) (bool, error)
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
    ServiceStatusDeleted  ServiceStatus = "deleted"  // Marked for deletion (soft delete)
)

// RegistrationSource indicates how a service was registered.
type RegistrationSource string

const (
    RegistrationSourceEdgeOnboarding RegistrationSource = "edge_onboarding"
    RegistrationSourceK8sSpiffe      RegistrationSource = "k8s_spiffe"
    RegistrationSourceConfig         RegistrationSource = "config"          // Static config file
    RegistrationSourceImplicit       RegistrationSource = "implicit"        // From heartbeat
)

// GatewayRegistration represents a gateway registration request.
type GatewayRegistration struct {
    GatewayID           string
    ComponentID        string // From edge onboarding package
    RegistrationSource RegistrationSource
    Metadata           map[string]string
    SPIFFEIdentity     string // Optional SPIFFE ID
    CreatedBy          string // Admin user ID or system
}

// AgentRegistration represents an agent registration request.
type AgentRegistration struct {
    AgentID            string
    GatewayID           string // Parent gateway (required)
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
    GatewayID           string // Grandparent gateway (denormalized for queries)
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
    ServiceType string // "gateway", "agent", "checker"
    GatewayID    string
    AgentID     string // Empty for gateways
    CheckerID   string // Empty for agents/gateways
    Timestamp   time.Time
    SourceIP    string
    Healthy     bool
    Metadata    map[string]string
}

// RegisteredGateway represents a registered gateway in the system.
type RegisteredGateway struct {
    GatewayID           string
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
    GatewayID           string
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
    GatewayID           string
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
-- Gateway registry
CREATE TABLE gateways_registry (
    gateway_id           string,
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
PRIMARY KEY (gateway_id)
ORDER BY (gateway_id, updated_at)
SETTINGS index_granularity = 8192;

-- Agent registry
CREATE TABLE agents_registry (
    agent_id            string,
    gateway_id           string,
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
ORDER BY (agent_id, gateway_id, updated_at)
SETTINGS index_granularity = 8192;

-- Checker registry
CREATE TABLE checkers_registry (
    checker_id          string,
    agent_id            string,
    gateway_id           string,
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
ORDER BY (checker_id, agent_id, gateway_id, updated_at)
SETTINGS index_granularity = 8192;

-- Service registration events (audit trail)
CREATE STREAM IF NOT EXISTS service_registration_events (
    event_id            string,
    event_type          string,  -- 'registered', 'activated', 'deactivated', 'revoked'
    service_id          string,
    service_type        string,  -- 'gateway', 'agent', 'checker'
    parent_id           string,  -- For agents: gateway_id, for checkers: agent_id
    registration_source string,
    actor               string,  -- Who performed the action
    timestamp           DateTime64(3),
    metadata            string   -- JSON
) ENGINE = Stream(1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 86400)
ORDER BY (timestamp, service_type, service_id)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

**Design Notes:**
- **ReplacingMergeTree** for registry tables - supports updates via inserts with `updated_at`
- **No automatic TTL on registry tables** - persistent record, but manual deletion supported
- **Nullable first_seen/last_seen** - distinguish "never reported" from "reported once"
- **Denormalized gateway_id in checkers** - easier queries, acceptable redundancy
- **Audit stream** - 90-day retention for compliance/debugging
- **Deletion Strategy** - See "Deletion and Retention Policy" section below

---

## Deletion and Retention Policy

### Problem: Unbounded Growth

Without a deletion mechanism, the registry tables will grow indefinitely. Even with status-based filtering (e.g., only querying 'active' services), the underlying tables continue to accumulate records.

### Solution: Multi-Tier Deletion Strategy

#### 1. Soft Delete (Status: deleted)

When a service is no longer needed but you want to retain audit trail:

```go
// Mark service as deleted (soft delete)
err := serviceRegistry.UpdateServiceStatus(ctx, serviceID, registry.ServiceStatusDeleted)
```

- Service moves to `deleted` status
- No longer appears in active queries
- Still in database for audit/historical purposes
- Can be hard deleted later by background job

#### 2. Hard Delete (Permanent Removal)

For immediate permanent deletion:

```go
// Permanently delete a service
err := serviceRegistry.DeleteService(ctx, "gateway", gatewayID)
```

**Implementation**:
```go
func (r *ServiceRegistry) DeleteService(ctx context.Context, serviceType, serviceID string) error {
    // Verify service is not active
    var status string
    query := `SELECT status FROM gateways_registry WHERE gateway_id = ? LIMIT 1`
    if err := r.db.QueryRow(ctx, query, serviceID).Scan(&status); err != nil {
        return fmt.Errorf("service not found: %w", err)
    }

    if status == string(ServiceStatusActive) || status == string(ServiceStatusPending) {
        return fmt.Errorf("cannot delete active or pending service: %s", serviceID)
    }

    // Emit deletion event BEFORE deleting
    r.emitRegistrationEvent(ctx, "deleted", serviceType, serviceID, "", "manual", getUserFromContext(ctx))

    // Hard delete from table using ALTER TABLE DELETE
    // Note: In ClickHouse/Timeplus, deletes are asynchronous and may take time
    deleteQuery := `ALTER TABLE gateways_registry DELETE WHERE gateway_id = ?`
    if err := r.db.Exec(ctx, deleteQuery, serviceID); err != nil {
        return fmt.Errorf("failed to delete service: %w", err)
    }

    // Invalidate cache
    r.invalidateGatewayCache()

    return nil
}
```

**Important**: In ClickHouse/CNPG/Timescale:
- `ALTER TABLE DELETE` is asynchronous - rows marked for deletion but not immediately removed
- Deleted rows still counted in table size until merge happens
- Use `OPTIMIZE TABLE FINAL` to force merge (expensive operation)

#### 3. Automated Purge (Background Job)

For automatic cleanup of old inactive/revoked/deleted services:

```go
// Background job runs daily
func (r *ServiceRegistry) PurgeInactive(ctx context.Context, retentionPeriod time.Duration) (int, error) {
    cutoff := time.Now().UTC().Add(-retentionPeriod)

    // Find services to purge: inactive/revoked/deleted for > retention period
    query := `SELECT service_type, service_id
              FROM (
                  SELECT 'gateway' AS service_type, gateway_id AS service_id, updated_at, status
                  FROM gateways_registry
                  WHERE status IN ('inactive', 'revoked', 'deleted')
                  AND updated_at < ?

                  UNION ALL

                  SELECT 'agent', agent_id, updated_at, status
                  FROM agents_registry
                  WHERE status IN ('inactive', 'revoked', 'deleted')
                  AND updated_at < ?

                  UNION ALL

                  SELECT 'checker', checker_id, updated_at, status
                  FROM checkers_registry
                  WHERE status IN ('inactive', 'revoked', 'deleted')
                  AND updated_at < ?
              )`

    rows, err := r.db.Query(ctx, query, cutoff, cutoff, cutoff)
    if err != nil {
        return 0, fmt.Errorf("failed to query stale services: %w", err)
    }
    defer rows.Close()

    count := 0
    for rows.Next() {
        var serviceType, serviceID string
        if err := rows.Scan(&serviceType, &serviceID); err != nil {
            continue
        }

        if err := r.DeleteService(ctx, serviceType, serviceID); err != nil {
            r.logger.Warn().Err(err).Str("service_id", serviceID).Msg("Failed to purge service")
            continue
        }
        count++
    }

    return count, nil
}
```

### Retention Recommendations

**Default Retention Periods**:
- **Active services**: Never deleted automatically
- **Pending services**: 30 days (if never activated)
- **Inactive services**: 90 days after last heartbeat
- **Revoked services**: 90 days after revocation
- **Deleted services**: 7 days (grace period for recovery)

**Configuration**:
```yaml
service_registry:
  retention:
    pending_days: 30      # Delete pending services that never activated
    inactive_days: 90     # Delete inactive services after this period
    revoked_days: 90      # Delete revoked services after this period
    deleted_days: 7       # Hard delete soft-deleted services after grace period
  purge_schedule: "0 2 * * *"  # Daily at 2 AM
```

### Service Lifecycle with Deletion

```
pending → active → inactive → [soft delete] → [hard delete]
   ↓                  ↓            ↓               ↓
revoked → [soft delete] → [hard delete]

States:
- pending: Registered but never reported (auto-purge after 30 days)
- active: Currently reporting (never auto-deleted)
- inactive: Stopped reporting (auto-purge after 90 days)
- revoked: Admin revoked (auto-purge after 90 days)
- deleted: Soft deleted (auto-purge after 7 days)
- [removed]: Hard deleted via ALTER TABLE DELETE
```

### API Endpoints for Deletion

```go
// Admin endpoints
DELETE /api/admin/services/gateways/{id}      // Hard delete
DELETE /api/admin/services/agents/{id}
DELETE /api/admin/services/checkers/{id}

PUT /api/admin/services/{id}/status          // Soft delete (status: deleted)
{
  "status": "deleted"
}

POST /api/admin/services/purge               // Manual purge trigger
{
  "retention_days": 90,
  "dry_run": true  // Preview what would be deleted
}
```

### Audit Trail Preservation

Even after hard deletion from registry tables, the audit stream retains events for 90 days:

- `service_registration_events` stream has 90-day TTL
- All deletion events (`event_type: 'deleted'`) logged
- Provides historical record of what was deleted and when
- Enables forensics and compliance reporting

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

    // Cache for IsKnownGateway() - invalidated on registration changes
    gatewayCacheMu sync.RWMutex
    gatewayCache   map[string]bool
    cacheExpiry   time.Time
}

func NewServiceRegistry(database db.Service, log logger.Logger) *ServiceRegistry {
    return &ServiceRegistry{
        db:          database,
        logger:      log,
        gatewayCache: make(map[string]bool),
    }
}
```

### Key Methods

#### RegisterGateway

```go
func (r *ServiceRegistry) RegisterGateway(ctx context.Context, reg *GatewayRegistration) error {
    now := time.Now().UTC()

    // Check if already exists
    existing, err := r.GetGateway(ctx, reg.GatewayID)
    if err == nil && existing != nil {
        // Already registered - return error or update?
        return fmt.Errorf("gateway %s already registered", reg.GatewayID)
    }

    // Insert into gateways_registry
    query := `INSERT INTO gateways_registry (
        gateway_id, component_id, status, registration_source,
        first_registered, metadata, spiffe_identity, created_by, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`

    metadataJSON, _ := json.Marshal(reg.Metadata)

    err = r.db.Exec(ctx, query,
        reg.GatewayID,
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
        return fmt.Errorf("failed to register gateway: %w", err)
    }

    // Emit registration event
    r.emitRegistrationEvent(ctx, "registered", "gateway", reg.GatewayID, "", reg.RegistrationSource, reg.CreatedBy)

    // Invalidate cache
    r.invalidateGatewayCache()

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
    case "gateway":
        return r.recordGatewayHeartbeat(ctx, heartbeat.GatewayID, now, heartbeat.SourceIP)
    case "agent":
        return r.recordAgentHeartbeat(ctx, heartbeat.AgentID, heartbeat.GatewayID, now, heartbeat.SourceIP)
    case "checker":
        return r.recordCheckerHeartbeat(ctx, heartbeat.CheckerID, heartbeat.AgentID, heartbeat.GatewayID, now)
    default:
        return fmt.Errorf("unknown service type: %s", heartbeat.ServiceType)
    }
}

func (r *ServiceRegistry) recordGatewayHeartbeat(ctx context.Context, gatewayID string, timestamp time.Time, sourceIP string) error {
    // Update last_seen, activate if pending, set first_seen if null
    query := `INSERT INTO gateways_registry (
        gateway_id, status, first_seen, last_seen, updated_at
    ) SELECT
        ?,
        if(status = 'pending', 'active', status) AS new_status,
        coalesce(first_seen, ?) AS new_first_seen,
        ? AS new_last_seen,
        ? AS updated_at
    FROM gateways_registry
    WHERE gateway_id = ?
    LIMIT 1`

    err := r.db.Exec(ctx, query, gatewayID, timestamp, timestamp, timestamp, gatewayID)
    if err != nil {
        return fmt.Errorf("failed to record gateway heartbeat: %w", err)
    }

    // Check if status changed to active
    gateway, _ := r.GetGateway(ctx, gatewayID)
    if gateway != nil && gateway.Status == ServiceStatusActive && gateway.FirstSeen != nil && gateway.FirstSeen.Equal(timestamp) {
        // First activation
        r.emitRegistrationEvent(ctx, "activated", "gateway", gatewayID, "", gateway.RegistrationSource, "system")
    }

    return nil
}
```

#### IsKnownGateway (Replaces core logic)

```go
const gatewayCacheTTL = 5 * time.Minute

func (r *ServiceRegistry) IsKnownGateway(ctx context.Context, gatewayID string) (bool, error) {
    // Check cache first
    r.gatewayCacheMu.RLock()
    if time.Now().Before(r.cacheExpiry) {
        known, exists := r.gatewayCache[gatewayID]
        r.gatewayCacheMu.RUnlock()
        if exists {
            return known, nil
        }
    }
    r.gatewayCacheMu.RUnlock()

    // Query database
    query := `SELECT COUNT(*) FROM gateways_registry
              WHERE gateway_id = ? AND status IN ('pending', 'active')`

    var count int
    row := r.db.QueryRow(ctx, query, gatewayID)
    if err := row.Scan(&count); err != nil {
        return false, fmt.Errorf("failed to check gateway: %w", err)
    }

    known := count > 0

    // Update cache
    r.gatewayCacheMu.Lock()
    if time.Now().After(r.cacheExpiry) {
        // Refresh entire cache
        r.refreshGatewayCache(ctx)
    } else {
        r.gatewayCache[gatewayID] = known
    }
    r.gatewayCacheMu.Unlock()

    return known, nil
}

func (r *ServiceRegistry) refreshGatewayCache(ctx context.Context) {
    query := `SELECT gateway_id FROM gateways_registry WHERE status IN ('pending', 'active')`
    rows, err := r.db.Query(ctx, query)
    if err != nil {
        r.logger.Warn().Err(err).Msg("Failed to refresh gateway cache")
        return
    }
    defer rows.Close()

    newCache := make(map[string]bool)
    for rows.Next() {
        var gatewayID string
        if err := rows.Scan(&gatewayID); err != nil {
            continue
        }
        newCache[gatewayID] = true
    }

    r.gatewayCache = newCache
    r.cacheExpiry = time.Now().Add(gatewayCacheTTL)
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
    case models.EdgeOnboardingComponentTypeGateway:
        err := s.serviceRegistry.RegisterGateway(ctx, &registry.GatewayRegistration{
            GatewayID:           gatewayID,
            ComponentID:        pkg.ComponentID,
            RegistrationSource: registry.RegistrationSourceEdgeOnboarding,
            Metadata:           req.Metadata,
            SPIFFEIdentity:     req.DownstreamSPIFFEID,
            CreatedBy:          getUserFromContext(ctx),
        })
        if err != nil {
            return nil, fmt.Errorf("failed to register gateway: %w", err)
        }
    case models.EdgeOnboardingComponentTypeAgent:
        err := s.serviceRegistry.RegisterAgent(ctx, &registry.AgentRegistration{
            AgentID:            req.ComponentID,
            GatewayID:           req.ParentID,
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

**In `pkg/core/gateways.go`:**

```go
// OLD:
func (s *Server) isKnownGateway(ctx context.Context, gatewayID string) bool {
    for _, known := range s.config.KnownGateways {
        if known == gatewayID {
            return true
        }
    }

    if s.edgeOnboarding != nil {
        if s.edgeOnboarding.isGatewayAllowed(ctx, gatewayID) {
            return true
        }
    }

    return false
}

// NEW:
func (s *Server) isKnownGateway(ctx context.Context, gatewayID string) bool {
    // Backwards compatibility: check static config first
    for _, known := range s.config.KnownGateways {
        if known == gatewayID {
            return true
        }
    }

    // Primary path: check service registry
    if s.serviceRegistry != nil {
        known, err := s.serviceRegistry.IsKnownGateway(ctx, gatewayID)
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
            GatewayID:    gatewayID,
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
- [ ] Add heartbeat recording from `PushStatus` RPC
- [ ] Replace `isKnownGateway()` to use service registry
- [ ] Integration tests

### Phase 3: API & UI (Week 2)
- [ ] Add REST API endpoints:
  - `GET /api/admin/services/gateways`
  - `GET /api/admin/services/agents`
  - `GET /api/admin/services/checkers`
  - `GET /api/admin/services/{id}`
- [ ] Add service registry dashboard to UI
- [ ] Show parent-child relationships

### Phase 4: K8s Integration (Week 3)
- [ ] Add SPIRE Controller webhook for service registration
- [ ] Register K8s services automatically on `ClusterSPIFFEID` creation
- [ ] Test with demo namespace

### Phase 5: Background Jobs & Deletion (Week 3)
- [ ] Implement `MarkInactive()` background job
- [ ] Implement `PurgeInactive()` background job with configurable retention
- [ ] Implement `DeleteService()` for manual hard deletion
- [ ] Add DELETE API endpoints for service removal
- [ ] Add alerting for services stuck in 'pending' state
- [ ] Add metrics collection (including purge stats)

### Phase 6: Migration & Cleanup (Week 4)
- [ ] Backfill existing services from `services` stream
- [ ] Update all documentation
- [ ] Remove legacy gateway tracking code from edge onboarding
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
- Caching for high-frequency queries (`IsKnownGateway`)
- Batch operations for efficiency
- Background jobs for maintenance

---

## Security Considerations

1. **Authorization:**
   - Only admins can register services explicitly
   - Heartbeats from authenticated connections only
   - Audit all registration events

2. **Data Validation:**
   - Validate parent references (agent → gateway, checker → agent)
   - Prevent duplicate registrations
   - Sanitize metadata

3. **SPIFFE Integration:**
   - Store SPIFFE IDs in registry
   - Cross-reference with SPIRE server state
   - Alert on mismatches

---

## Future Enhancements

### Service Dependencies
Track dependencies between services (e.g., agent depends on gateway being healthy).

### Service Mesh Integration
Export service registry to service mesh control plane.

### Auto-Decommission
Automatically revoke services that have been inactive for extended periods.

### Multi-Tenancy
Extend registry to support multi-tenant deployments with namespace isolation.

---

## Conclusion

Extending `pkg/registry` to handle service registration provides a unified, authoritative system for tracking all gateways, agents, and checkers. This design:

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
