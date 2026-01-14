# Sysmon Consolidation - Design Document

## Context

ServiceRadar currently has two separate system monitoring implementations:
- **sysmon-osx** (Go): Uses `gopsutil`, runs as standalone gRPC checker on macOS
- **sysmon** (Rust): Uses `sysinfo` crate, runs as standalone gRPC checker on Linux

Both implement the same `monitoring.AgentService` gRPC interface but are separate binaries that the agent connects to as external checkers. This creates:
- Maintenance burden (two codebases, two languages)
- Deployment complexity (separate binary per platform)
- Feature drift (Rust version has ZFS support, Go version has better CPU frequency handling)
- Configuration management is per-machine JSON files only

## Goals

1. **Unify codebase**: Single Go library replacing both implementations
2. **Simplify deployment**: Embed sysmon directly in agent (no separate checker process)
3. **Centralized management**: UI-based profile management with SRQL-based device targeting
4. **Backward compatibility**: Support local config override for automation/air-gapped scenarios
5. **Feature parity**: Ensure no regression from either existing implementation

## Non-Goals

1. Windows support (not currently supported, out of scope)
2. Custom alerting/thresholds engine (use existing observability pipeline)
3. Real-time streaming metrics (batch collection is sufficient)
4. ZFS support in v1 (can be added later, not critical path)

## Decisions

### Decision 1: Embed sysmon in agent vs. keep as external checker

**Decision**: Embed as library in `serviceradar-agent`

**Rationale**:
- Eliminates inter-process gRPC overhead
- Simplifies deployment (one binary instead of two)
- Enables direct config integration without IPC
- Reduces attack surface (no additional listening ports)

**Alternatives considered**:
- Keep external checker pattern: Rejected because it adds deployment complexity and latency
- Make sysmon a plugin: Rejected because Go doesn't have great plugin support cross-platform

**Trade-offs**:
- Agent binary size increases (~2-3MB for gopsutil)
- Agent restart required for sysmon library updates (acceptable)

### Decision 2: Configuration priority (local vs. remote)

**Decision**: Local config takes full precedence (no merge)

**Rationale**:
- Clear mental model: "If I have a local file, that's what runs"
- Supports air-gapped/compliance scenarios where remote config is forbidden
- Enables testing with local overrides
- Ansible/automation users can deploy configs without backend dependency

**Alternatives considered**:
- Merge local + remote: Rejected because partial merges are confusing and error-prone
- Remote always wins: Rejected because it breaks air-gapped and automation use cases
- Environment variable override: Could be added later, not needed for v1

### Decision 3: Profile targeting model (SRQL-based)

**Decision**: Use SRQL queries for device targeting instead of explicit assignments

**Rationale**:
- SRQL provides powerful, flexible device matching (tags, hostname patterns, device type, etc.)
- Single targeting mechanism reduces complexity vs. multiple assignment types
- Profiles with `target_query` are evaluated by priority (highest first)
- No need for separate assignment table or per-device assignment management
- Consistent with other SRQL usage in the platform

**Priority order**:
1. Local file (highest)
2. SRQL-targeted profiles (evaluated by priority descending, first match wins)
3. Default tenant profile (lowest)

### Decision 4: Configuration delivery mechanism

**Decision**: Extend existing `GetConfig` gRPC RPC, not new endpoint

**Rationale**:
- Agent already calls `GetConfig` on startup
- Minimal protocol changes
- Reuses existing auth/connection logic

**Changes needed**:
- Add `SysmonConfig` to `AgentConfigResponse` message
- Backend resolves profile → compiles to config → returns in response

### Decision 5: Ash resource structure

**Decision**: Single resource `SysmonProfile` with SRQL targeting via `target_query` field

**Rationale**:
- Simpler than separate assignment table
- SRQL query provides all needed flexibility (tags, hostname patterns, device attributes)
- Priority field enables deterministic resolution order
- Default profile has `is_default: true` and no `target_query`

**Schema**:
```
SysmonProfile
├── id (UUID)
├── name (unique per tenant)
├── description
├── sample_interval (string, e.g., "10s")
├── collect_* flags (booleans)
├── disk_paths[] (array of strings)
├── thresholds (map)
├── target_query (string, nullable) - SRQL query for device matching
├── priority (integer, default 0) - higher = evaluated first
├── is_default (boolean)
├── enabled (boolean)
└── tenant_id (UUID)
```

**Resolution via SrqlTargetResolver**:
1. Load profiles with `target_query` ordered by priority DESC
2. For each profile, execute `{target_query} uid:{device_uid}`
3. Return first profile with non-empty match
4. Fall back to default profile if no SRQL match

### Decision 6: Default profile handling

**Decision**: Seed default profile on tenant creation, mark as `is_default=true`

**Rationale**:
- Ensures every agent gets a working config
- Admin can modify default but not delete
- Simple query: `WHERE is_default = true AND tenant_id = ?`

**Default settings**:
```json
{
  "enabled": true,
  "sample_interval": "10s",
  "collect_cpu": true,
  "collect_memory": true,
  "collect_disk": true,
  "collect_network": false,
  "collect_processes": false,
  "disk_paths": ["/"]
}
```

### Decision 7: Library structure (`pkg/sysmon`)

**Decision**: Single package with platform-specific files via build tags

**Structure**:
```
pkg/sysmon/
├── collector.go       # Main collector, platform-agnostic
├── config.go          # Configuration types
├── metrics.go         # MetricSample and related types
├── cpu.go             # CPU collection (uses gopsutil)
├── cpu_darwin.go      # macOS-specific CPU handling
├── memory.go          # Memory collection
├── disk.go            # Disk collection
├── network.go         # Network collection
├── process.go         # Process collection
└── collector_test.go  # Tests
```

**Key interfaces**:
```go
type Collector interface {
    Start(ctx context.Context) error
    Stop() error
    Collect() (*MetricSample, error)
    Reconfigure(config Config) error
}

type Config struct {
    Enabled          bool
    SampleInterval   time.Duration
    CollectCPU       bool
    CollectMemory    bool
    CollectDisk      bool
    CollectNetwork   bool
    CollectProcesses bool
    DiskPaths        []string
    ProcessTopN      int
    Thresholds       map[string]string
}
```

## Risks and Mitigations

### Risk: gopsutil gaps on specific platforms
**Mitigation**: Comprehensive testing on both macOS (Intel + Apple Silicon) and Linux (Debian, RHEL). Document any platform-specific limitations.

### Risk: Breaking existing sysmon checker users
**Mitigation**: Keep external checker pattern working in parallel during transition. Deprecation notice with 2 release cycles before removal.

### Risk: Profile changes cause metric gaps
**Mitigation**: Agent applies config changes gracefully (stop old collector, start new). Brief gap is acceptable; no data loss.

### Risk: Many agents polling for config simultaneously
**Mitigation**: Agent adds jitter to refresh interval (0-30s). Backend caches compiled configs.

## Migration Plan

### Phase 1: Library Foundation ✅
1. Create `pkg/sysmon` with gopsutil
2. Port sysmon-osx logic to new library
3. Add Linux-specific paths
4. Unit tests for cross-platform parity

### Phase 2: Agent Integration ✅
1. Add sysmon collector initialization to agent
2. Implement local config loading
3. Add config caching
4. Integration tests with agent

### Phase 3: Backend & Config Delivery ✅
1. Create `SysmonProfile` Ash resource with SRQL targeting fields
2. Create `SrqlTargetResolver` module for profile-to-device matching
3. Implement `SysmonCompiler` for profile-to-config compilation
4. Extend GetConfig RPC with SysmonConfig
5. Add ConfigInvalidationNotifier hooks
6. Seed default profile on tenant creation

### Phase 4: UI ✅
1. Sysmon Profiles page (CRUD with SRQL query builder)
2. Profile targeting via SRQL query with live match preview
3. Device detail sysmon section (read-only, shows matched profile)
4. Agent list with sysmon status

### Phase 5: Deprecation ✅
1. Mark standalone sysmon/sysmon-osx as deprecated
2. Add migration docs
3. Remove standalone checkers

### Phase 6: Cleanup ✅
1. Remove `cmd/checkers/sysmon/` (Rust)
2. Remove `cmd/checkers/sysmon-osx/` (Go)
3. Remove `pkg/checker/sysmonosx/` (legacy)
4. Remove all sysmon packaging (Bazel, specs, Dockerfiles)
5. Update CI workflows to remove sysmon references
6. Migrate macOS codesign/notarization to agent packaging

## Open Questions

1. **Q: Should we support Windows in future?**
   A: Out of scope for v1. gopsutil supports Windows, so library is extensible.

2. **Q: How do we handle when device matches multiple profiles?**
   A: Profiles are evaluated by priority (highest first). First SRQL match wins.

3. **Q: Should profile changes be instant or wait for refresh?**
   A: Wait for refresh (default 5 min). Could add push mechanism via NATS later for instant updates.

4. **Q: Include ZFS support from Rust version?**
   A: Deferred to v2. Not critical for initial consolidation.
