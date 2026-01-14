# Tasks

## Phase 1: Library Foundation (`pkg/sysmon`)

- [x] 1.1 Create `pkg/sysmon/config.go` with Config struct and JSON marshaling
- [x] 1.2 Create `pkg/sysmon/metrics.go` with MetricSample struct (compatible with Rust output)
- [x] 1.3 Create `pkg/sysmon/collector.go` with Collector interface and base implementation
- [x] 1.4 Implement `pkg/sysmon/cpu.go` CPU metrics using gopsutil
- [x] 1.5 Add `pkg/sysmon/cpu_darwin.go` for macOS-specific CPU frequency handling (via cpufreq package)
- [x] 1.6 Implement `pkg/sysmon/memory.go` memory metrics using gopsutil
- [x] 1.7 Implement `pkg/sysmon/disk.go` disk metrics with configurable paths
- [x] 1.8 Implement `pkg/sysmon/network.go` network interface metrics
- [x] 1.9 Implement `pkg/sysmon/process.go` process collection (all processes, backend decides topN)
- [x] 1.10 Write unit tests for all metric collectors
- [x] 1.11 Verify MetricSample JSON output matches existing Rust sysmon format
- [x] 1.12 Test on macOS (Intel and Apple Silicon)
- [ ] 1.13 Test on Linux (Debian-based and RHEL-based)

## Phase 2: Agent Integration

- [x] 2.1 Add `SysmonConfig` to agent config structures
- [x] 2.2 Implement local config loader in agent (`loadLocalSysmonConfig()`)
- [x] 2.3 Add config file path detection (Linux vs macOS paths)
- [x] 2.4 Initialize sysmon collector in agent `Server.Start()`
- [x] 2.5 Integrate sysmon metrics into agent status reports
- [x] 2.6 Implement config caching to `/var/lib/serviceradar/cache/`
- [x] 2.7 Add periodic config refresh loop (default 5 min with jitter)
- [x] 2.8 Implement graceful collector reconfiguration on config change
- [x] 2.9 Add logging for config source (local/remote/cached/default)
- [x] 2.10 Write integration tests for agent + embedded sysmon

## Phase 3: Protocol & Backend

### 3.1 Protobuf Updates
- [x] 3.1.1 Define `SysmonConfig` message in `proto/monitoring.proto`
- [x] 3.1.2 Add `sysmon_config` field to `AgentConfigResponse`
- [x] 3.1.3 Regenerate Go and Elixir protobuf code
- [x] 3.1.4 Update agent to parse `SysmonConfig` from `GetConfig` response
- [x] 3.1.5 Update agent to use `StreamStatus` for sysmon (large payloads)
- [x] 3.1.6 Set Source field to `sysmon-metrics` (distinct from SNMP, etc.)

### 3.2 Ash Resources (Elixir)
- [x] 3.2.1 Create `SysmonProfile` resource in `serviceradar_core`
- [x] 3.2.2 Create `SysmonProfileAssignment` resource with device/tag polymorphism
- [x] 3.2.3 Add tenant isolation policies to both resources
- [x] 3.2.4 Create migrations for sysmon_profiles and sysmon_profile_assignments tables
- [x] 3.2.5 Add domain registration for sysmon resources
- [x] 3.2.6 Regenerate Elixir protobuf code with SysmonConfig message

### 3.3 Config Compilation
- [x] 3.3.1 Create `SysmonCompiler` module following `SweepCompiler` pattern
- [x] 3.3.2 Implement profile resolution logic (device → tag → default)
- [x] 3.3.3 Compile profile to JSON matching agent schema
- [x] 3.3.4 Integrate with `ConfigInvalidationNotifier` for change propagation
- [x] 3.3.5 Add caching for compiled configs (via ConfigServer)

### 3.4 Default Profile
- [x] 3.4.1 Seed default SysmonProfile on tenant creation
- [x] 3.4.2 Mark default profile with `is_default: true` attribute
- [x] 3.4.3 Add policy preventing deletion of default profile
- [x] 3.4.4 Write tests for default profile seeding

### 3.5 Config Delivery
- [x] 3.5.1 Update `GetConfig` RPC handler to include sysmon config
- [x] 3.5.2 Add sysmon profile resolution in config response builder
- [x] 3.5.3 Test end-to-end config delivery (unit tests for AgentConfigGenerator sysmon integration)

### 3.6 Agent-to-Device Integration
- [x] 3.6.1 Add `ensure_device_for_agent` to AgentGatewaySync module
- [x] 3.6.2 Use DIRE to resolve device identity from agent hostname/IP
- [x] 3.6.3 Create/update device record on agent enrollment (hello)
- [x] 3.6.4 Link agent to device via `device_uid` field
- [x] 3.6.5 Set `discovery_sources: ["agent"]` for agent-created devices
- [x] 3.6.6 Test agent enrollment creates device in inventory (agent_gateway_sync_test.exs)

## Phase 4: Web UI (`web-ng`)

### 4.1 Sysmon Profiles Page
- [x] 4.1.1 Create route: Settings → Sysmon Profiles
- [x] 4.1.2 Implement profile list view with columns (name, interval, assignments)
- [x] 4.1.3 Add "Create Profile" form with all config fields
- [x] 4.1.4 Add "Edit Profile" form with pre-populated values
- [x] 4.1.5 Add "Delete Profile" with reassignment confirmation
- [x] 4.1.6 Add JSON preview panel for compiled config
- [x] 4.1.7 Add "System" badge for default profile
- [x] 4.1.8 Disable delete for default profile

### 4.2 Tag Assignments
- [x] 4.2.1 Add "Tag Assignments" tab to Sysmon Profiles page
- [x] 4.2.2 Implement tag → profile assignment form
- [x] 4.2.3 Show device count per tag assignment
- [x] 4.2.4 Add remove assignment action

### 4.3 Device Integration
- [x] 4.3.1 Add "Sysmon Profile" column to Devices list (optional)
- [x] 4.3.2 Add "System Monitoring" section to Device detail page
- [x] 4.3.3 Show effective profile with source (direct/tag/default)
- [x] 4.3.4 Add "Local Override" badge when agent uses local config
- [x] 4.3.5 Add direct profile assignment dropdown to Device detail
- [x] 4.3.6 Add bulk "Assign Sysmon Profile" action to Devices list

### 4.4 Agent Visibility
- [x] 4.4.1 Add sysmon status to existing Agent views
- [x] 4.4.2 Add sysmon discovery_source for SRQL filtering (`discovery_sources:sysmon`)
- [x] 4.4.3 Add filter by config source (remote/local) - added `config_source` field and SRQL filter

## Phase 5: Testing & Documentation

- [x] 5.1 End-to-end test: Create profile → assign to tag → verify agent receives config (sysmon_profile_assignment_test.exs)
- [x] 5.2 Test local override takes precedence over remote (TestLocalOverrideTakesPrecedence in sysmon_service_test.go)
- [x] 5.3 Test config caching when backend unavailable (TestCacheFallbackWhenLocalUnavailable in sysmon_service_test.go)
- [x] 5.4 Test default profile for new agents (covered in sysmon_profile_assignment_test.exs fallback test)
- [x] 5.5 Performance test: Config fetch latency with 1K/5K/10K agents
- [x] 5.6 Write user documentation for Sysmon Profiles UI (docs/docs/sysmon-profiles.md)
- [x] 5.7 Write admin documentation for local config override (docs/docs/sysmon-local-config.md)

## Phase 6: Deprecation & Cleanup

- [x] 6.1 Add deprecation notice to standalone sysmon/sysmon-osx READMEs
- [x] 6.2 Update installation docs to reflect embedded sysmon (docs/docs/installation.md)
- [x] 6.3 Create migration guide from standalone checker to embedded (docs/docs/runbooks/sysmon-migration.md)
- [ ] 6.4 Remove standalone sysmon builds from CI (after 2 releases)
- [ ] 6.5 Remove `cmd/checkers/sysmon/` (Rust)
- [ ] 6.6 Remove `cmd/checkers/sysmon-osx/` (Go)
- [ ] 6.7 Remove `pkg/checker/sysmonosx/` (legacy Go package)
