# ServiceRadar Onboarding Process Review (November 2025)

## Executive Summary

This document provides a comprehensive review of ServiceRadar's service onboarding processes across all deployment models: Kubernetes, Docker Compose, and edge deployments. The review examines how services register with Core, how agents associate with pollers, and identifies gaps in the current implementation.

**Key Findings:**
- ✅ **K8s onboarding is fully automated** via SPIFFE Controller and ClusterSPIFFEID CRDs
- ✅ **Edge onboarding has strong foundation** with zero-touch library (pkg/edgeonboarding)
- ⚠️ **Service registry is implicit** - no dedicated table tracking all known services
- ⚠️ **Agent registration is passive** - agents only appear when they report services
- ⚠️ **Checker onboarding automation is partial** - manual KV updates still required (GH-1909)
- ⚠️ **Main docker-compose stack lacks SPIFFE automation** - relies on static TLS certificates

---

## 1. Current Onboarding Mechanisms

### 1.1 Kubernetes Deployments

**Method:** Declarative SPIFFE Identity Assignment via Controller

**How It Works:**
1. SPIRE Controller Manager runs as sidecar in SPIRE Server StatefulSet
2. `ClusterSPIFFEID` CRDs define SPIFFE identities for workloads:
   ```yaml
   apiVersion: spire.spiffe.io/v1alpha1
   kind: ClusterSPIFFEID
   metadata:
     name: serviceradar-core
   spec:
     spiffeIDTemplate: spiffe://carverauto.dev/ns/demo/sa/serviceradar-core
     podSelector:
       matchLabels:
         app: serviceradar-core
   ```
3. Controller watches pod creation/deletion and automatically creates/deletes SPIRE registration entries
4. Workloads access SPIFFE Workload API via `/run/spire/sockets/agent.sock` mounted from DaemonSet

**Service Registration with Core:**
- Pollers appear as "known" once they have a `ClusterSPIFFEID` resource
- Core's `isKnownPoller()` checks:
  1. Static `KnownPollers` list in core config (legacy)
  2. Edge onboarding service's allowed poller list (dynamic, KV-backed)
- No explicit "registration" API call - pollers become known declaratively

**Status:** ✅ **Fully Automated** - Zero manual intervention after CRD creation

**Files:**
- `k8s/demo/base/spire/spire-clusterspiffeid-*.yaml` - Identity definitions
- `k8s/demo/base/spire/spire-controller-manager-rbac.yaml` - Controller RBAC
- `pkg/core/pollers.go:701` - `isKnownPoller()` function

---

### 1.2 Edge Deployments (Docker/Bare Metal)

**Method:** Token-Based Onboarding with Nested SPIRE

**How It Works:**

1. **Package Creation** (Admin → Core):
   ```bash
   serviceradar-cli edge create-package \
     --name "Remote Site A" \
     --type poller \
     --metadata-json "$(cat metadata.json)"
   ```
   - Core creates `EdgeOnboardingPackage` record with status `issued`
   - Generates SPIRE join token (15min TTL) and download token (24hr TTL)
   - Package includes:
     - `edge-poller.env` - Service configuration
     - `spire/upstream-join-token` - SPIRE attestation token
     - `spire/upstream-bundle.pem` - Trust bundle
     - `metadata.json` - Core/KV endpoints, SPIFFE IDs

2. **Package Download** (Edge Host → Core):
   ```bash
   # Via API with download token
   curl -H "Authorization: Bearer $TOKEN" \
     https://core/api/admin/edge-packages/download/$PACKAGE_ID
   ```
   - Package status changes to `delivered`

3. **Service Bootstrap** (Edge Host):
   ```bash
   # Zero-touch onboarding (implemented in GH-1915)
   docker run -e ONBOARDING_TOKEN=$TOKEN \
     ghcr.io/carverauto/serviceradar-poller:latest
   ```
   - `pkg/edgeonboarding` library handles:
     - Downloading package from Core
     - Extracting SPIRE credentials
     - Configuring nested SPIRE (upstream agent + downstream server)
     - Generating service configuration
     - Starting service

4. **Activation** (Poller → Core):
   - Poller sends first `ReportStatus` RPC to Core
   - Core calls `edgeOnboarding.RecordActivation()` in `pkg/core/services.go:869`
   - Package status changes to `activated`
   - Poller added to in-memory allowed list, broadcast to all Core instances

**Nested SPIRE Architecture:**
```
┌─────────────────────────────────────────────┐
│ Edge Site (Docker Compose)                  │
│                                              │
│  ┌──────────────────────────────────────┐  │
│  │ Poller Container                     │  │
│  │                                       │  │
│  │  ┌──────────────────────────────┐   │  │
│  │  │ SPIRE Upstream Agent         │   │  │
│  │  │ (connects to cluster SPIRE)  │   │  │
│  │  └──────────────────────────────┘   │  │
│  │                                       │  │
│  │  ┌──────────────────────────────┐   │  │
│  │  │ SPIRE Downstream Server      │   │  │
│  │  │ (issues certs to agent)      │   │  │
│  │  └──────────────────────────────┘   │  │
│  │                                       │  │
│  │  ┌──────────────────────────────┐   │  │
│  │  │ Poller Service               │   │  │
│  │  └──────────────────────────────┘   │  │
│  └──────────────────────────────────────┘  │
│                                              │
│  ┌──────────────────────────────────────┐  │
│  │ Agent Container (shares network/PID) │  │
│  │                                       │  │
│  │  ┌──────────────────────────────┐   │  │
│  │  │ SPIRE Downstream Agent       │   │  │
│  │  │ (gets cert from poller)      │   │  │
│  │  └──────────────────────────────┘   │  │
│  │                                       │  │
│  │  ┌──────────────────────────────┐   │  │
│  │  │ Agent Service                │   │  │
│  │  └──────────────────────────────┘   │  │
│  └──────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
           │
           │ SPIFFE mTLS
           ▼
┌─────────────────────────────────────────────┐
│ Cluster SPIRE Server (Kubernetes)            │
└─────────────────────────────────────────────┘
```

**Status:** ✅ **Implemented for Pollers** (GH-1915/serviceradar-57)
- Zero-touch onboarding working
- DataSvc self-registration implemented
- Checker template registration added

**Status:** ⚠️ **Partial for Agents/Checkers** (GH-1909 in progress)
- Can create agent/checker packages
- KV automation not complete
- Manual KV updates still required

**Files:**
- `pkg/edgeonboarding/` - Bootstrap library
- `pkg/core/edge_onboarding.go` - Package creation/activation
- `docker/compose/poller-stack.compose.yml` - Edge stack definition
- `docker/compose/bootstrap-nested-spire.sh` - SPIRE bootstrap helper

---

### 1.3 Main Docker Compose Stack

**Method:** Static TLS Certificates (Legacy)

**How It Works:**
1. `cert-generator` container runs `generate-certs.sh` to create self-signed certs
2. Certificates stored in `poller-cert-data` volume
3. Services mount certificates from volume
4. Services connect using TLS, not SPIFFE

**Status:** ⚠️ **Legacy Approach** - Not using SPIFFE/SPIRE
- Used for local development
- No automatic identity management
- Static certificates need manual rotation

**Note:** Per GH-1915, main docker-compose stack is intentionally separate from edge onboarding and should NOT be modified to include edge logic.

---

## 2. Service Registration and Tracking

### 2.1 Service Registry Architecture

**Key Finding:** ServiceRadar does NOT maintain a dedicated "service registry" table. Instead, services are tracked implicitly through the `services` stream.

**Services Stream Schema:**
```sql
CREATE STREAM IF NOT EXISTS services (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    service_name      string,
    service_type      string,
    config            string,
    partition         string
) ENGINE = Stream(1, rand())
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
```

**How Service Registration Works:**

1. **Poller Authorization** (`pkg/core/pollers.go:812`):
   ```go
   func (s *Server) ReportStatus(ctx context.Context, req *proto.PollerStatusRequest) {
       if !s.isKnownPoller(ctx, req.PollerId) {
           s.logger.Warn().Str("poller_id", req.PollerId).
               Msg("Ignoring status report from unknown poller")
           return &proto.PollerStatusResponse{Received: true}, nil
       }
       // Process status report...
   }
   ```

2. **Service Payload Processing** (`pkg/core/metrics.go:797`):
   - `processServicePayload()` handles each service in the status report
   - For gRPC checkers, calls `ensureServiceDevice()` to register the device
   - Extracts host IP/hostname from checker payload
   - Creates `DeviceUpdate` with `DiscoverySourceSelfReported`

3. **Service Storage** (`pkg/core/services.go:860`):
   - Services written to `services` stream
   - Includes `poller_id`, `agent_id`, `service_type`, `service_name`
   - Records become the implicit service registry

### 2.2 Agent-to-Poller Association

**Mechanism:** Agents are associated with pollers through the `services` stream, NOT through explicit registration.

**Query for Agent List** (`pkg/db/pollers.go:423`):
```sql
SELECT
    agent_id,
    poller_id,
    MAX(timestamp) as last_seen,
    groupArray(DISTINCT service_type) as service_types
FROM table(services)
WHERE agent_id != ''
GROUP BY agent_id, poller_id
ORDER BY last_seen DESC
```

**Key Implications:**
- Agents only appear after they start reporting services
- No "pre-registration" of agents
- Agent-poller relationship is derived, not declared
- If agent stops reporting, it disappears from the list (TTL = 3 days)

**Edge Onboarding Activation** (`pkg/core/services.go:876`):
```go
if s.edgeOnboarding != nil {
    if agentID != "" && agentID != pollerID {
        if err := s.edgeOnboarding.RecordActivation(ctx,
            models.EdgeOnboardingComponentTypeAgent,
            agentID, pollerID, sourceIP, "", timestamp); err != nil {
            // Log error but continue
        }
    }
}
```
- When services report with both `poller_id` and `agent_id`, Core calls `RecordActivation`
- This promotes edge-onboarded agents from "issued" to "activated"
- Updates `edge_onboarding_packages` table

### 2.3 Checker Registration

**Current State:** Checkers are registered implicitly like all other services.

**gRPC Checker Flow** (`pkg/core/devices.go:31`):
```go
func (s *Server) ensureServiceDevice(
    ctx context.Context,
    agentID, pollerID, partition string,
    svc *proto.ServiceStatus,
    serviceData json.RawMessage,
    timestamp time.Time,
) {
    // Only gRPC checkers embed host context
    if svc.ServiceType != grpcServiceType {
        return
    }

    hostIP, hostname, hostID := extractCheckerHostIdentity(serviceData)
    if hostIP == "" {
        return // Cannot register without IP
    }

    deviceID := fmt.Sprintf("%s:%s", partition, hostIP)

    metadata := map[string]string{
        "source":             "checker",
        "checker_service":    svc.ServiceName,
        "collector_agent_id": agentID,
        "collector_poller_id": pollerID,
        // ...
    }

    // Emit DeviceUpdate to device registry
    deviceUpdate := &models.DeviceUpdate{
        DeviceID:    deviceID,
        Source:      models.DiscoverySourceSelfReported,
        // ...
    }
}
```

**Checker Template Registration** (Implemented in serviceradar-57):
- Checkers self-register default templates to KV on startup
- Template stored at `templates/checkers/{kind}.json`
- Edge onboarding fetches template, applies variable substitution
- Writes instance config to `agents/{agent_id}/checkers/{kind}.json`

---

## 3. SPIFFE Identity Management

### 3.1 Kubernetes SPIFFE Flow

**Components:**
1. **SPIRE Server StatefulSet** (`spire-server-0`)
   - Runs upstream SPIRE server binary
   - Runs SPIRE Controller Manager sidecar
   - Stores state in CloudNativePG cluster (`spire-pg`)

2. **SPIRE Agent DaemonSet**
   - Runs on every node
   - Exposes Workload API at `/run/spire/sockets/agent.sock`
   - Uses `k8s_sat` node attestor (Kubernetes Service Account Tokens)

3. **SPIRE Controller Manager**
   - Watches `ClusterSPIFFEID` CRDs
   - Creates/updates SPIRE registration entries via admin API
   - Reconciles pod selectors automatically

**Identity Assignment:**
```yaml
# Example: serviceradar-core identity
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: serviceradar-core
spec:
  spiffeIDTemplate: spiffe://carverauto.dev/ns/demo/sa/serviceradar-core
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: demo
  podSelector:
    matchLabels:
      app: serviceradar-core
```

**Services with SPIFFE Identities in K8s:**
- ✅ serviceradar-core
- ✅ serviceradar-datasvc
- ✅ serviceradar-poller
- ✅ serviceradar-agent
- ✅ serviceradar-mapper
- ✅ serviceradar-sync
- ✅ serviceradar-db-event-writer
- ✅ serviceradar-flowgger
- ✅ serviceradar-trapd
- ✅ serviceradar-rperf-checker
- ✅ serviceradar-snmp-checker
- ✅ serviceradar-zen

### 3.2 Edge SPIFFE Flow (Nested SPIRE)

**Upstream Agent Attestation:**
- Edge poller's upstream agent connects to cluster SPIRE server
- Uses join token attestation (not `k8s_sat`)
- Join token stored in package: `spire/upstream-join-token`
- Parent ID: `spiffe://carverauto.dev/ns/edge/poller-nested-spire`
- Token TTL: 15 minutes (expires quickly for security)

**Downstream Server Configuration:**
- Poller runs nested SPIRE server for downstream workloads (agent, checkers)
- Bootstrap script (`bootstrap-nested-spire.sh`) creates downstream entries
- Downstream agent (in agent container) uses Unix selectors for attestation:
  ```
  unix:uid:0
  unix:gid:0
  unix:user:root
  unix:path:/opt/spire/bin/spire-server
  ```

**Network/PID Sharing:**
```yaml
# poller-stack.compose.yml
agent:
  network_mode: "service:poller"
  pid: "service:poller"
```
- Agent shares network namespace with poller (accesses localhost:50051)
- Agent shares PID namespace for SPIRE Workload API attestation

---

## 4. Identified Gaps

### 4.1 No Centralized Service Registry

**Gap:** There is no dedicated table or persistent store listing all registered services across the system.

**Current Behavior:**
- Services are tracked only in the ephemeral `services` stream (3-day TTL)
- Query `ListAgentsWithPollers()` derives agents from recent service reports
- If agent stops reporting, it disappears from system view after 3 days
- No historical record of what services existed

**Impact:**
- Cannot answer "what services are registered in the system?" without querying time-series data
- Cannot distinguish between "service stopped reporting" vs "service was never onboarded"
- No persistent association between agent and poller
- Cannot pre-register agents/checkers before they start reporting

**Recommendation:**
Create dedicated registration tables:

```sql
-- Persistent poller registry
CREATE TABLE pollers_registry (
    poller_id           string,
    component_id        string,  -- from edge onboarding
    status              string,  -- 'pending', 'active', 'inactive', 'revoked'
    first_registered    DateTime64(3),
    last_seen           DateTime64(3),
    registration_source string,  -- 'edge_onboarding', 'k8s_spiffe', 'config'
    metadata            string   -- JSON
) PRIMARY KEY poller_id;

-- Persistent agent registry
CREATE TABLE agents_registry (
    agent_id            string,
    poller_id           string,  -- parent poller
    component_id        string,  -- from edge onboarding
    status              string,
    first_registered    DateTime64(3),
    last_seen           DateTime64(3),
    registration_source string,
    metadata            string
) PRIMARY KEY agent_id;

-- Persistent checker registry
CREATE TABLE checkers_registry (
    checker_id          string,
    agent_id            string,  -- parent agent
    poller_id           string,  -- grandparent poller
    checker_kind        string,  -- 'snmp', 'sysmon', 'rperf', etc.
    status              string,
    first_registered    DateTime64(3),
    last_seen           DateTime64(3),
    registration_source string,
    metadata            string
) PRIMARY KEY checker_id;
```

**Benefits:**
- Clear audit trail of all services ever registered
- Pre-registration support (mark as 'pending' before first report)
- Distinguish between "never reported" vs "stopped reporting"
- Persistent agent-to-poller associations
- Support for "list all pollers" without relying on time-series data

---

### 4.2 Agent/Checker Onboarding Not Fully Automated

**Gap:** While poller onboarding is fully automated, agent and checker onboarding still requires manual KV updates (GH-1909 not complete).

**Current Agent Onboarding:**
1. ✅ Can create agent package via API
2. ⚠️ Package creation does NOT update KV automatically
3. ❌ Must manually update `config/pollers/<poller-id>/agents/<agent-id>.json` in KV
4. ⚠️ Agent only becomes "known" after it starts reporting services

**Current Checker Onboarding:**
1. ✅ Checker templates can be registered automatically (serviceradar-57)
2. ⚠️ Must manually update `config/agents/<agent-id>/checkers/<checker-id>.json` in KV
3. ❌ No UI/API to create checker packages linked to agents

**Expected Flow (from GH-1909):**
```
Admin creates agent package with parent_id=poller-123
  → Core automatically writes config/pollers/poller-123/agents/agent-456.json
  → Status: 'pending'

Agent first reports in
  → Core updates agent config status to 'active'
  → Poller immediately starts routing work to agent
```

**Recommendation:**
1. Complete GH-1909 implementation:
   - Auto-create KV entries on package creation
   - Support agent and checker package types
   - Validate parent exists (poller for agent, agent for checker)
   - Update status from 'pending' → 'active' on first report

2. Implement checker package creation:
   ```bash
   serviceradar-cli edge create-package \
     --type checker \
     --parent-id agent-456 \
     --checker-kind sysmon \
     --metadata-json "$(cat sysmon-config.json)"
   ```

---

### 4.3 No Pre-Registration Support

**Gap:** Services must start reporting before they appear in the system. Cannot pre-register services.

**Use Cases That Don't Work:**
1. Admin wants to prepare 10 agents for a new site
   - Cannot create agent records in advance
   - Cannot verify configuration before deployment
   - Cannot assign agents to pollers before they start

2. Admin wants to see "pending" services that haven't checked in yet
   - No way to distinguish "hasn't reported yet" from "doesn't exist"
   - Cannot track deployment progress

3. Admin wants to allocate agent IDs before deployment
   - Agent IDs are generated at package creation
   - But agent doesn't appear in system until first report
   - Cannot verify agent configuration remotely before install

**Recommendation:**
Use the proposed `*_registry` tables (Gap 4.1) with status tracking:
- `pending` - Package created, waiting for first report
- `active` - Service is reporting
- `inactive` - Service stopped reporting (exceeded threshold)
- `revoked` - Package was revoked

This enables:
- Pre-registration via edge package creation
- Clear deployment progress tracking
- Verification of expected vs actual services

---

### 4.4 Main Docker Compose Stack Not Using SPIFFE

**Gap:** The main docker-compose stack (used for local development) still uses static TLS certificates, not SPIFFE/SPIRE.

**Current Behavior:**
- `cert-generator` container creates self-signed certificates
- Services mount certificates from shared volume
- No automatic rotation, no central identity management
- Different authentication path than K8s and edge deployments

**Rationale (from GH-1915):**
- Main stack is for local development and trusted environments
- Edge onboarding is intentionally separate
- K8s uses SPIFFE Controller, edge uses nested SPIRE, main uses static certs

**Impact:**
- Developers test with different auth model than production
- Certificate rotation is manual
- No unified SPIFFE story across all deployment models

**Recommendation:**
This appears to be intentional architectural decision. Document the three authentication models clearly:
1. **K8s Production:** SPIFFE Controller + ClusterSPIFFEID CRDs
2. **Edge Sites:** Nested SPIRE with join tokens
3. **Local Development:** Static TLS certificates

If unifying is desired, consider running a lightweight SPIRE setup in docker-compose, but this may add unnecessary complexity for local development.

---

### 4.5 Join Token Expiration Friction

**Gap:** SPIRE join tokens expire after 15 minutes, creating deployment friction for edge sites.

**Current Behavior:**
1. Admin creates edge package with join token
2. Token expires in 15 minutes
3. If edge site doesn't deploy within 15 minutes, installation fails
4. Must create new package and re-distribute

**Impact:**
- Manual coordination required between package creation and deployment
- Cannot pre-stage packages for later deployment
- Difficult to automate deployment pipelines

**Workaround:**
`pkg/edgeonboarding` library could implement automatic token refresh:
1. Package includes refresh token (longer TTL)
2. On bootstrap, if join token expired, request new one via refresh token
3. Continue with onboarding

**Recommendation:**
This is marked as "Out of Scope (Future Work)" in GH-1915. Consider prioritizing if edge deployments become frequent.

Alternative: Support X.509 PoP attestation for edge sites where join tokens are impractical.

---

### 4.6 No Service Health Dashboard

**Gap:** While individual services report health, there's no centralized view of all registered services and their health status.

**Current Behavior:**
- Can query `/api/admin/pollers` to see pollers
- Can query `/api/admin/agents` to see agents (recently added)
- No unified view of:
  - Which services are registered
  - Which are healthy vs unhealthy
  - Which are pending activation
  - Which have stopped reporting

**Recommendation:**
Create unified service registry dashboard:
- List all pollers, agents, checkers with status
- Show parent-child relationships (agent → poller, checker → agent)
- Highlight services that haven't reported recently
- Show pending edge onboarding packages

This requires implementing Gap 4.1 (centralized service registry) first.

---

### 4.7 SPIRE Server Credentials in Kubernetes

**Gap:** From GH-1891, SPIRE database credentials are stored in a YAML file with placeholder password.

**File:** `k8s/demo/base/spire/spire-db-credentials.yaml`

**Current Approach:**
- Placeholder password in source control
- Admin must manually generate and apply real password
- Easy to forget, easy to commit secrets accidentally

**Recommendation:**
Use Kubernetes External Secrets Operator or similar:
1. Store SPIRE database credentials in HashiCorp Vault / AWS Secrets Manager
2. External Secrets Operator syncs to Kubernetes Secret
3. SPIRE StatefulSet references the synced Secret
4. No secrets in source control, automatic rotation support

---

## 5. Architecture Strengths

### 5.1 Clean Separation of Onboarding Models

**Strength:** The system correctly separates three distinct onboarding models without conflating them:

1. **K8s (Trusted):** ClusterSPIFFEID CRDs + Controller Manager
   - Fully declarative
   - Native Kubernetes integration
   - Zero touch for pod-based services

2. **Edge (Untrusted):** Package-based onboarding with nested SPIRE
   - Token-based authentication
   - Supports disconnected/intermittent connectivity
   - Designed for hostile networks

3. **Local Dev:** Static certificates in docker-compose
   - Simple, no external dependencies
   - Fast iteration for developers

**Benefit:** Each model is optimized for its use case. No "one size fits all" compromise.

---

### 5.2 Edge Onboarding Library (pkg/edgeonboarding)

**Strength:** The common onboarding library (from GH-1915/serviceradar-57) provides excellent abstraction.

**Features:**
- ✅ Zero-touch bootstrap with single token
- ✅ Automatic package download and extraction
- ✅ SPIRE credential configuration
- ✅ Service config generation
- ✅ Deployment type detection (Docker vs bare metal)

**Code Quality:**
- Well-tested
- Clear separation of concerns
- Reusable across all edge services

**Impact:** Drastically reduces edge deployment complexity. Single command vs 5+ shell scripts.

---

### 5.3 Implicit Service Discovery

**Strength:** The implicit service registry (services via heartbeat) has advantages:

**Benefits:**
- Self-healing - services that stop reporting automatically disappear
- No stale data - only active services are visible
- Simple implementation - no explicit registration API needed
- Loose coupling - services don't need to know about registration

**Trade-offs:**
- Lack of pre-registration (Gap 4.3)
- No historical view (Gap 4.1)
- Cannot distinguish "never existed" from "stopped reporting"

**Verdict:** Good design for operational visibility, needs supplement for management/audit use cases.

---

### 5.4 Nested SPIRE for Edge

**Strength:** Using nested SPIRE for edge deployments is architecturally sound.

**Benefits:**
- Edge sites get their own trust boundary
- Reduces load on central SPIRE server
- Edge continues working if connection to cluster is lost (downstream SVIDs still issued)
- Proper security model for untrusted networks

**Implementation:**
- Poller runs both upstream agent (to cluster) and downstream server (for edge)
- Agent/checkers get SVIDs from poller's downstream server
- Network/PID namespace sharing enables Workload API attestation

---

## 6. Recommendations Summary

### Priority 1: Complete Agent/Checker Automation (GH-1909)

**Action Items:**
1. Complete automatic KV updates on agent package creation
   - Write to `config/pollers/<poller-id>/agents/<agent-id>.json`
   - Set status: 'pending'

2. Implement checker package creation
   - Support parent_id (agent) validation
   - Auto-update `config/agents/<agent-id>/checkers/<checker-id>.json`
   - Include checker-specific metadata (credentials, targets)

3. Update UI to support component type selection
   - Dropdown for poller/agent/checker
   - Parent selector for agents and checkers
   - Metadata forms tailored to component type

**Impact:** Eliminates manual KV updates, major friction point for edge deployments

---

### Priority 2: Create Centralized Service Registry

**Action Items:**
1. Add registry tables:
   - `pollers_registry`
   - `agents_registry`
   - `checkers_registry`

2. Update Core to write to registry on:
   - Edge package activation
   - First service report from new service
   - K8s pod creation (via ClusterSPIFFEID reconciliation hook)

3. Implement status tracking:
   - 'pending' → 'active' → 'inactive' → 'revoked'
   - Background job to mark as 'inactive' if no reports for X hours

4. Add registry queries to API:
   - `GET /api/admin/services/pollers`
   - `GET /api/admin/services/agents`
   - `GET /api/admin/services/checkers`
   - Include status, parent relationships, last_seen

**Impact:** Enables pre-registration, historical audit, service lifecycle management

---

### Priority 3: Service Health Dashboard

**Action Items:**
1. Create unified UI dashboard showing:
   - All registered services (from registry)
   - Health status (active/inactive/pending)
   - Parent-child relationships
   - Pending edge packages awaiting activation

2. Add filters:
   - By status
   - By component type
   - By poller/agent
   - By registration source

3. Add alerting for:
   - Services pending activation > 30 minutes
   - Services that stopped reporting unexpectedly
   - Edge packages with expired join tokens

**Impact:** Operational visibility, proactive issue detection

---

### Priority 4: Document Onboarding Models

**Action Items:**
1. Update documentation to clearly explain three models:
   - K8s (ClusterSPIFFEID)
   - Edge (pkg/edgeonboarding + nested SPIRE)
   - Local dev (static TLS)

2. Document when to use each model
3. Document trade-offs and security implications
4. Create decision tree for onboarding new services

**Impact:** Reduces confusion, helps operators choose correct approach

---

### Priority 5: Secret Management in K8s

**Action Items:**
1. Replace static SPIRE DB credentials with External Secrets Operator
2. Document secret management best practices
3. Implement credential rotation procedures

**Impact:** Security hardening, prevent accidental credential leakage

---

## 7. Conclusion

ServiceRadar has a solid onboarding foundation with excellent separation of concerns across deployment models. The K8s SPIFFE Controller provides fully automated onboarding for cluster deployments, and the new edge onboarding library (GH-1915) drastically simplifies edge deployments.

**Key Strengths:**
- ✅ Clean architectural separation (K8s/Edge/Dev)
- ✅ Zero-touch edge onboarding library
- ✅ Nested SPIRE for edge security
- ✅ Implicit service discovery via heartbeat

**Key Gaps:**
- ⚠️ No centralized service registry
- ⚠️ Agent/checker automation incomplete (GH-1909)
- ⚠️ No pre-registration support
- ⚠️ Main docker-compose uses static TLS
- ⚠️ Join token expiration friction
- ⚠️ No unified service health dashboard

**Recommended Next Steps:**
1. Complete GH-1909 (agent/checker automation) - **Highest Priority**
2. Implement centralized service registry
3. Build service health dashboard
4. Document onboarding models clearly

These improvements will eliminate remaining manual steps, provide better operational visibility, and complete the zero-touch onboarding vision outlined in GH-1891.

---

## References

- GH-1891: Implement zero-touch onboarding across the ServiceRadar stack
- GH-1909: Edge onboarding: support agents and checkers
- GH-1915 / serviceradar-57: Create common onboarding library to eliminate edge deployment friction
- GH-1899: feat: onboarding agents
- `docs/docs/edge-agent-onboarding.md` - Edge agent onboarding guide
- `docs/docs/edge-onboarding.md` - Edge onboarding runbook
- `docs/docs/custom-checkers.md` - Custom checker development guide
- `docs/docs/spiffe-identity.md` - SPIFFE/SPIRE platform documentation
- `docs/docs/spire-onboarding-plan.md` - SPIRE integration planning
- `pkg/edgeonboarding/` - Edge onboarding library implementation
- `pkg/core/edge_onboarding.go` - Core edge onboarding service
- `pkg/core/pollers.go` - Poller management and isKnownPoller()
- `pkg/core/devices.go` - Device registration via checkers
- `pkg/db/pollers.go` - Poller/agent database queries
- `k8s/demo/base/spire/` - Kubernetes SPIFFE/SPIRE manifests
- `docker/compose/poller-stack.compose.yml` - Edge deployment stack

---

*Document created: November 1, 2025*
*Author: ServiceRadar Core Team*
*Status: Review Complete*
