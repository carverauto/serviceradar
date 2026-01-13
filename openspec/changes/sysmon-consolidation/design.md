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
3. **Centralized management**: UI-based profile management with tag-based assignments
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

### Decision 3: Profile assignment model (direct vs. tag-based)

**Decision**: Support both direct device assignment AND tag-based assignment

**Rationale**:
- Tags enable scalable management (assign once, applies to all matching devices)
- Direct assignment allows exceptions ("this specific server needs special config")
- Mirrors existing SweepProfile pattern which works well

**Priority order**:
1. Local file (highest)
2. Direct device assignment
3. Tag-based assignment (most recently assigned tag wins if multiple match)
4. Default profile (lowest)

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

**Decision**: Two resources: `SysmonProfile` and `SysmonProfileAssignment`

**Rationale**:
- Follows existing `SweepProfile` + `SweepGroup` pattern
- Clean separation between profile definition and assignment
- Supports both device and tag assignments in one table

**Schema**:
```
SysmonProfile
├── id (UUID)
├── name (unique per tenant)
├── description
├── sample_interval_ms
├── collect_* flags
├── disk_paths[]
├── thresholds (embedded)
├── is_default (boolean)
└── tenant_id

SysmonProfileAssignment
├── id (UUID)
├── profile_id → SysmonProfile
├── device_id → Device (nullable)
├── tag_name (string, nullable)
├── priority (integer)
└── tenant_id

Constraint: (device_id IS NOT NULL) XOR (tag_name IS NOT NULL)
```

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

### Phase 1: Library Foundation
1. Create `pkg/sysmon` with gopsutil
2. Port sysmon-osx logic to new library
3. Add Linux-specific paths
4. Unit tests for cross-platform parity

### Phase 2: Agent Integration
1. Add sysmon collector initialization to agent
2. Implement local config loading
3. Add config caching
4. Integration tests with agent

### Phase 3: Backend & Config Delivery
1. Create Ash resources (SysmonProfile, SysmonProfileAssignment)
2. Implement SysmonCompiler
3. Extend GetConfig RPC with SysmonConfig
4. Add ConfigInvalidationNotifier hooks
5. Seed default profile on tenant creation

### Phase 4: UI
1. Sysmon Profiles page (CRUD)
2. Tag assignment UI
3. Device detail sysmon section
4. Agent list with sysmon status

### Phase 5: Deprecation
1. Mark standalone sysmon/sysmon-osx as deprecated
2. Add migration docs
3. Remove standalone checkers after 2 releases

## Open Questions

1. **Q: Should we support Windows in future?**
   A: Out of scope for v1. gopsutil supports Windows, so library is extensible.

2. **Q: How do we handle config conflicts when device has multiple tags?**
   A: Most recently created tag assignment wins. Could add explicit priority field later.

3. **Q: Should profile changes be instant or wait for refresh?**
   A: Wait for refresh (default 5 min). Could add push mechanism via NATS later for instant updates.

4. **Q: Include ZFS support from Rust version?**
   A: Deferred to v2. Not critical for initial consolidation.
