# Tasks

## Phase 1: Library Foundation (`pkg/sysmon`)

- [ ] 1.1 Create `pkg/sysmon/config.go` with Config struct and JSON marshaling
- [ ] 1.2 Create `pkg/sysmon/metrics.go` with MetricSample struct (compatible with Rust output)
- [ ] 1.3 Create `pkg/sysmon/collector.go` with Collector interface and base implementation
- [ ] 1.4 Implement `pkg/sysmon/cpu.go` CPU metrics using gopsutil
- [ ] 1.5 Add `pkg/sysmon/cpu_darwin.go` for macOS-specific CPU frequency handling
- [ ] 1.6 Implement `pkg/sysmon/memory.go` memory metrics using gopsutil
- [ ] 1.7 Implement `pkg/sysmon/disk.go` disk metrics with configurable paths
- [ ] 1.8 Implement `pkg/sysmon/network.go` network interface metrics
- [ ] 1.9 Implement `pkg/sysmon/process.go` top-N process collection
- [ ] 1.10 Write unit tests for all metric collectors
- [ ] 1.11 Verify MetricSample JSON output matches existing Rust sysmon format
- [ ] 1.12 Test on macOS (Intel and Apple Silicon)
- [ ] 1.13 Test on Linux (Debian-based and RHEL-based)

## Phase 2: Agent Integration

- [ ] 2.1 Add `SysmonConfig` to agent config structures
- [ ] 2.2 Implement local config loader in agent (`loadLocalSysmonConfig()`)
- [ ] 2.3 Add config file path detection (Linux vs macOS paths)
- [ ] 2.4 Initialize sysmon collector in agent `Server.Start()`
- [ ] 2.5 Integrate sysmon metrics into agent status reports
- [ ] 2.6 Implement config caching to `/var/lib/serviceradar/cache/`
- [ ] 2.7 Add periodic config refresh loop (default 5 min with jitter)
- [ ] 2.8 Implement graceful collector reconfiguration on config change
- [ ] 2.9 Add logging for config source (local/remote/cached/default)
- [ ] 2.10 Write integration tests for agent + embedded sysmon

## Phase 3: Protocol & Backend

### 3.1 Protobuf Updates
- [ ] 3.1.1 Define `SysmonConfig` message in `proto/monitoring.proto`
- [ ] 3.1.2 Add `sysmon_config` field to `AgentConfigResponse`
- [ ] 3.1.3 Regenerate Go and Elixir protobuf code
- [ ] 3.1.4 Update agent to parse `SysmonConfig` from `GetConfig` response

### 3.2 Ash Resources (Elixir)
- [ ] 3.2.1 Create `SysmonProfile` resource in `serviceradar_core`
- [ ] 3.2.2 Create `SysmonProfileAssignment` resource with device/tag polymorphism
- [ ] 3.2.3 Add tenant isolation policies to both resources
- [ ] 3.2.4 Create migrations for sysmon_profiles and sysmon_profile_assignments tables
- [ ] 3.2.5 Add domain registration for sysmon resources

### 3.3 Config Compilation
- [ ] 3.3.1 Create `SysmonCompiler` module following `SweepCompiler` pattern
- [ ] 3.3.2 Implement profile resolution logic (local → device → tag → default)
- [ ] 3.3.3 Compile profile to JSON matching agent schema
- [ ] 3.3.4 Integrate with `ConfigInvalidationNotifier` for change propagation
- [ ] 3.3.5 Add caching for compiled configs

### 3.4 Default Profile
- [ ] 3.4.1 Seed default SysmonProfile on tenant creation
- [ ] 3.4.2 Mark default profile with `is_default: true`
- [ ] 3.4.3 Add policy preventing deletion of default profile
- [ ] 3.4.4 Write tests for default profile seeding

### 3.5 Config Delivery
- [ ] 3.5.1 Update `GetConfig` RPC handler to include sysmon config
- [ ] 3.5.2 Add sysmon profile resolution in config response builder
- [ ] 3.5.3 Test end-to-end config delivery from UI to agent

## Phase 4: Web UI (`web-ng`)

### 4.1 Sysmon Profiles Page
- [ ] 4.1.1 Create route: Settings → Sysmon Profiles
- [ ] 4.1.2 Implement profile list view with columns (name, interval, assignments)
- [ ] 4.1.3 Add "Create Profile" form with all config fields
- [ ] 4.1.4 Add "Edit Profile" form with pre-populated values
- [ ] 4.1.5 Add "Delete Profile" with reassignment confirmation
- [ ] 4.1.6 Add JSON preview panel for compiled config
- [ ] 4.1.7 Add "System" badge for default profile
- [ ] 4.1.8 Disable delete for default profile

### 4.2 Tag Assignments
- [ ] 4.2.1 Add "Tag Assignments" tab to Sysmon Profiles page
- [ ] 4.2.2 Implement tag → profile assignment form
- [ ] 4.2.3 Show device count per tag assignment
- [ ] 4.2.4 Add remove assignment action

### 4.3 Device Integration
- [ ] 4.3.1 Add "Sysmon Profile" column to Devices list (optional)
- [ ] 4.3.2 Add "System Monitoring" section to Device detail page
- [ ] 4.3.3 Show effective profile with source (direct/tag/default)
- [ ] 4.3.4 Add "Local Override" badge when agent uses local config
- [ ] 4.3.5 Add direct profile assignment dropdown to Device detail
- [ ] 4.3.6 Add bulk "Assign Sysmon Profile" action to Devices list

### 4.4 Agent Visibility
- [ ] 4.4.1 Add sysmon status to existing Agent views
- [ ] 4.4.2 Add filter by sysmon profile
- [ ] 4.4.3 Add filter by config source (remote/local)

## Phase 5: Testing & Documentation

- [ ] 5.1 End-to-end test: Create profile → assign to tag → verify agent receives config
- [ ] 5.2 Test local override takes precedence over remote
- [ ] 5.3 Test config caching when backend unavailable
- [ ] 5.4 Test default profile for new agents
- [ ] 5.5 Performance test: Config fetch latency with 1000 agents
- [ ] 5.6 Write user documentation for Sysmon Profiles UI
- [ ] 5.7 Write admin documentation for local config override

## Phase 6: Deprecation & Cleanup

- [ ] 6.1 Add deprecation notice to standalone sysmon/sysmon-osx READMEs
- [ ] 6.2 Update installation docs to reflect embedded sysmon
- [ ] 6.3 Create migration guide from standalone checker to embedded
- [ ] 6.4 Remove standalone sysmon builds from CI (after 2 releases)
- [ ] 6.5 Remove `cmd/checkers/sysmon/` (Rust)
- [ ] 6.6 Remove `cmd/checkers/sysmon-osx/` (Go)
- [ ] 6.7 Remove `pkg/checker/sysmonosx/` (legacy Go package)
