# Edge Onboarding Friction Points

This document details the friction points discovered during E2E testing of the edge onboarding process, along with proposed solutions.

## Critical Issues

### 1. SQL DELETE Syntax Error

**Issue**: Core crashes on startup when trying to delete unknown pollers from the database.

**Error**:
```
failed to prepare batch: code: 62, message: Syntax error: failed at position 1 ('DELETE'):
DELETE FROM table(pollers) WHERE poller_id = $1 VALUES
```

**Location**: `/home/mfreeman/serviceradar/pkg/db/pollers.go:195`

**Root Cause**: Incorrect ClickHouse DELETE syntax. ClickHouse doesn't support `DELETE FROM table()` with PrepareBatch.

**Original Code**:
```go
batch, err := db.Conn.PrepareBatch(ctx, "DELETE FROM table(pollers) WHERE poller_id = $1")
```

**Fix**:
```go
query := "ALTER TABLE pollers DELETE WHERE poller_id = $1"
if err := db.Conn.Exec(ctx, query, pollerID); err != nil {
    return fmt.Errorf("%w: failed to delete poller: %w", ErrFailedToInsert, err)
}
```

**Status**: ✅ **FIXED** - Updated code, built successfully, needs deployment

**Impact**: HIGH - Prevents Core from starting with unknown pollers in database

---

### 2. Manual Poller Registration Required

**Issue**: Pollers must be manually added to Core's `known_pollers` ConfigMap, requiring kubectl access and Core restart.

**Current Process**:
```bash
# 1. Get config
kubectl -n demo get configmap serviceradar-config -o json | \
  jq -r '.data."core.json"' > /tmp/core.json

# 2. Add poller ID
jq '.known_pollers += ["docker-poller-e2e-03"]' /tmp/core.json > /tmp/core-updated.json

# 3. Update ConfigMap
kubectl -n demo patch configmap serviceradar-config --type merge -p \
  "$(jq -n --arg core "$(cat /tmp/core-updated.json)" '{data: {"core.json": $core}}')"

# 4. Restart Core
kubectl -n demo rollout restart deployment/serviceradar-core
```

**Friction Points**:
- Requires kubectl access to production cluster
- Requires Core restart (downtime)
- Error-prone manual process
- Not scalable for many edge deployments

**Proposed Solution**:
Edge onboarding should automatically register pollers in an allowed list. Two approaches:

**Option A** - Database-based (Recommended):
- `isKnownPoller()` already checks `edgeOnboarding.isPollerAllowed()`
- This queries the `edge_packages` table for packages with status in [Issued, Delivered, Activated]
- **Issue**: Packages use `component_id` but pollers report with custom `poller_id`
- **Fix**: Add `allowed_poller_id` column to edge_packages table
- Update package creation to set: `allowed_poller_id = poller_id_override OR component_id`
- No ConfigMap updates needed

**Option B** - Hybrid:
- Keep static `known_pollers` for legacy pollers
- Edge packages automatically allowed via database
- No restarts required

**Impact**: MEDIUM - Workaround exists but adds operational overhead

**Status**: 🔴 **NOT FIXED** - Requires database schema change

---

### 3. Authentication Required for Package Management API

**Issue**: Cannot easily create or manage edge packages via API without complex authentication.

**Current State**:
- `/api/admin/edge-packages/*` endpoints exist
- Return `401 Invalid API key` without authentication
- Login endpoint `/auth/login` requires valid credentials
- No documented admin password in test environment

**Attempted**:
```bash
curl -s -X POST "http://localhost:8090/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin"}'
# Returns: login failed: invalid credentials
```

**Impact**: MEDIUM - Can work around by accessing Core pod directly or via UI

**Workaround**:
```bash
# Option 1: Use kubectl exec
kubectl -n demo exec deployment/serviceradar-core -- \
  curl -s http://localhost:8090/api/admin/edge-packages

# Option 2: Use Web UI (requires browser)
```

**Proposed Solution**:
1. **Short-term**: Document default admin credentials or provide reset script
2. **Long-term**: Create `serviceradar-cli edge` commands:
   ```bash
   serviceradar-cli edge create-package --name "Test Poller" --type poller
   serviceradar-cli edge list-packages
   serviceradar-cli edge revoke-package <id>
   ```

**Status**: 🟡 **WORKAROUND AVAILABLE** - Can use kubectl exec or UI

---

## Medium Issues

### 4. DNS Resolution from Docker to Kubernetes

**Issue**: Edge pollers running in Docker cannot resolve Kubernetes DNS names.

**Examples**:
- `serviceradar-core:50052` → Not resolvable
- `serviceradar-datasvc:50057` → Not resolvable
- `spire-server.demo.svc.cluster.local` → Not resolvable

**Current Solution**: Manual IP address conversion

**Automated in setup-edge-e2e.sh**:
```bash
sed -i 's|CORE_ADDRESS=serviceradar-core:50052|CORE_ADDRESS=23.138.124.18:50052|g'
sed -i 's|KV_ADDRESS=serviceradar-datasvc:50057|KV_ADDRESS=23.138.124.23:50057|g'
sed -i 's|POLLERS_SPIRE_UPSTREAM_ADDRESS=spire-server.demo.svc.cluster.local|POLLERS_SPIRE_UPSTREAM_ADDRESS=23.138.124.18|g'
```

**Ideal Solution**:
- Edge package generation should detect deployment type (Docker vs K8s)
- For Docker deployments, use LoadBalancer IPs directly in generated configs
- Add `--deployment-type docker` flag to package creation

**Impact**: LOW - Automated in setup script

**Status**: ✅ **AUTOMATED** - Setup script handles this

---

### 5. UUID Poller IDs Instead of Readable Names

**Issue**: Pollers default to using package UUID (e.g., `ce492405-a4ed-404d-bece-7044a0bb7798`) instead of readable names.

**Impact on Operations**:
- Logs difficult to read
- Hard to identify which poller is which
- Not obvious in monitoring dashboards

**Current Workaround**:
```bash
# Add to edge-poller.env
POLLERS_POLLER_ID=docker-poller-e2e-02
```

**Proposed Solution**:
- Package creation UI should require a readable `poller_id`
- Default to extracting from SPIFFE ID suffix: `spiffe://carverauto.dev/ns/edge/docker-poller-e2e-02` → `docker-poller-e2e-02`
- Validate format: alphanumeric + hyphens only

**Impact**: LOW - Automated in setup script

**Status**: ✅ **AUTOMATED** - Setup script extracts from SPIFFE ID

---

### 6. Network Namespace Configuration

**Issue**: Agent must share poller's network namespace to access nested SPIRE workload socket.

**Configuration Required**:
```yaml
services:
  agent:
    network_mode: "service:poller"
    pid: "service:poller"
```

**Why Required**:
- Agent needs access to `/run/spire/nested/workload/agent.sock`
- Socket is in poller's mount namespace
- Poller also acts as SPIFFE workload API proxy

**Current State**: Already configured in `/home/mfreeman/serviceradar/docker/compose/poller-stack.compose.yml`

**Documentation**: Needs to be documented as a requirement

**Impact**: VERY LOW - Already configured correctly

**Status**: ✅ **RESOLVED** - Configuration is correct

---

## Low Priority Issues

### 7. SPIRE SQLite vs PostgreSQL

**Comment from User**:
> "what is this crap? POLLERS_SPIRE_SQLITE_PATH="${POLLERS_SPIRE_SQLITE_PATH:-/run/spire/nested/server/datastore.sqlite3}" we dont use sqlite at all in this project"

**Clarification**:
- This is **SPIRE's internal datastore**, not ServiceRadar's
- SPIRE Server (the nested server running in edge poller) needs a datastore for:
  - Workload registration entries
  - Attestation data
  - Node entries
  - Join tokens

**SPIRE Datastore Options**:
1. **SQLite** (current) - Embedded, no dependencies
2. **PostgreSQL** - Requires running PostgreSQL container
3. **MySQL** - Requires running MySQL container

**For Edge Deployments**:
- SQLite is actually **recommended** by SPIRE project
- Reduces dependencies (no separate DB container needed)
- Suitable for edge scale (single server, limited workloads)
- Persistent via Docker volume

**If PostgreSQL is Required**:
```yaml
# Add to poller-stack.compose.yml
services:
  poller-postgres:
    image: postgres:14
    environment:
      POSTGRES_DB: spire
      POSTGRES_USER: spire
      POSTGRES_PASSWORD: spire
    volumes:
      - poller-postgres-data:/var/lib/postgresql/data

  poller:
    depends_on:
      - poller-postgres
    # Update SPIRE config to use postgres://poller-postgres:5432/spire
```

**Recommendation**: Keep SQLite for edge deployments. It's appropriate for this use case.

**Impact**: VERY LOW - Current configuration is appropriate

**Status**: ✅ **NO ACTION NEEDED** - SQLite is correct choice

---

### 8. Join Token Expiration

**Issue**: SPIRE join tokens expire after 15 minutes.

**Impact**: If download delayed, token becomes invalid.

**Current Handling**:
- `edge-poller-restart.sh` automatically refreshes credentials
- Creates new join token from upstream SPIRE server
- Safe to run multiple times

**Proposed Improvement**:
- Increase default TTL to 30 or 60 minutes
- Add `--join-token-ttl` flag to package creation
- Document expiration prominently in package README

**Impact**: VERY LOW - Easy to regenerate

**Status**: 🟡 **MINOR IMPROVEMENT NEEDED** - Increase default TTL

---

## Summary of Actions

### Completed ✅
1. Fixed SQL DELETE syntax error in Core
2. Created idempotent setup script (`setup-edge-e2e.sh`)
3. Automated DNS to IP conversion
4. Automated readable poller ID extraction
5. Created package management utility (`manage-packages.sh`)
6. Documented all issues and solutions
7. Verified network namespace configuration

### Requires Code Changes 🔴
1. **Critical**: Update Core image with SQL DELETE fix
2. **High Priority**: Auto-register pollers via edge_packages table
3. **Medium Priority**: Add CLI commands for package management
4. **Low Priority**: Improve join token handling

### Requires Documentation 📝
1. Edge onboarding process (✅ SETUP_GUIDE.md created)
2. Troubleshooting guide (✅ README.md created)
3. API authentication (needs update)
4. Default credentials documentation

### Quick Wins 🎯
1. Increase join token TTL from 15m to 30m (config change)
2. Add deployment type detection to package generation
3. Require readable poller_id in package creation UI

## Testing Status

**What Works**:
- ✅ Package download and extraction
- ✅ SPIRE credential bootstrap
- ✅ Configuration generation
- ✅ Network namespace sharing
- ✅ Agent-poller communication
- ✅ SPIFFE/mTLS authentication
- ✅ Status reporting to Core (after manual registration)

**What Needs Testing**:
- ⏳ Full flow with SQL DELETE fix deployed
- ⏳ Package creation via API (auth issues)
- ⏳ Auto-registration via edge_packages (not implemented)
- ⏳ Multiple simultaneous pollers

## Recommendations

### Immediate (This Sprint)
1. Deploy Core with SQL DELETE fix
2. Test full onboarding flow end-to-end
3. Document default admin credentials
4. Update package creation to include readable poller IDs

### Short-term (Next Sprint)
1. Implement auto-registration via edge_packages table
2. Add serviceradar-cli edge commands
3. Improve API documentation
4. Increase join token default TTL

### Long-term (Future)
1. Add edge deployment health monitoring
2. Implement automatic credential rotation
3. Create edge deployment dashboard
4. Add multi-region support
