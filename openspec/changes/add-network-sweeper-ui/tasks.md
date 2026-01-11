# Tasks: Network Sweeper UI and Config Distribution

## Phase 1: AgentConfig Foundation

### 1.1 Ash Domain Setup
- [ ] 1.1.1 Create `ServiceRadar.AgentConfig` domain module
- [ ] 1.1.2 Create `ConfigTemplate` Ash resource with tenant isolation
- [ ] 1.1.3 Create `ConfigInstance` Ash resource for compiled configs
- [ ] 1.1.4 Create `ConfigVersion` Ash resource for version history
- [ ] 1.1.5 Generate Ash migrations for config tables
- [ ] 1.1.6 Add policy authorizers for config resources

### 1.2 Config Compiler Infrastructure
- [ ] 1.2.1 Define `ServiceRadar.AgentConfig.Compiler` behaviour
- [ ] 1.2.2 Implement `ConfigCache` ETS-based caching module
- [ ] 1.2.3 Implement `ConfigServer` GenServer for compilation orchestration
- [ ] 1.2.4 Create `ConfigPublisher` for NATS event publishing
- [ ] 1.2.5 Wire up Ash change notifications to invalidate cache

### 1.3 gRPC Config Endpoint
- [ ] 1.3.1 Add `config_type` field to `AgentConfigRequest` proto
- [ ] 1.3.2 Add `config_hash` and `has_changes` fields to response proto
- [ ] 1.3.3 Implement config routing in gateway `GetConfig` handler
- [ ] 1.3.4 Add gateway-side config caching with NATS invalidation
- [ ] 1.3.5 Implement core-elx RPC endpoint for config compilation

---

## Phase 2: Sweep Job Resources

### 2.1 Sweep Domain Setup
- [ ] 2.1.1 Create `ServiceRadar.SweepJobs` domain module
- [ ] 2.1.2 Create `SweepProfile` Ash resource
- [ ] 2.1.3 Create `SweepGroup` Ash resource with target_criteria
- [ ] 2.1.4 Create `SweepGroupExecution` Ash resource
- [ ] 2.1.5 Create `SweepHostResult` Ash resource
- [ ] 2.1.6 Generate Ash migrations for sweep tables
- [ ] 2.1.7 Add policy authorizers (admin-only for profiles)

### 2.2 Device Targeting DSL
- [ ] 2.2.1 Implement `TargetCriteria` module for DSL parsing
- [ ] 2.2.2 Implement criteria-to-SRQL compiler
- [ ] 2.2.3 Add `in_cidr` operator for IP range matching
- [ ] 2.2.4 Add `contains` operator for array fields (discovery_sources)
- [ ] 2.2.5 Implement target count preview query
- [ ] 2.2.6 Add validation for target_criteria attribute

### 2.3 Sweep Config Compiler
- [ ] 2.3.1 Implement `SweepCompiler` behaviour module
- [ ] 2.3.2 Compile SweepGroup to agent JSON format
- [ ] 2.3.3 Evaluate target_criteria at compile time
- [ ] 2.3.4 Merge profile settings with group overrides
- [ ] 2.3.5 Handle multiple groups per agent (merge configs)
- [ ] 2.3.6 Populate device_targets with metadata

---

## Phase 3: Settings UI - Networks Tab

### 3.1 Scanner Profiles UI (Admin)
- [ ] 3.1.1 Create `NetworksLive` LiveView module
- [ ] 3.1.2 Create `ProfilesComponent` for profile list/CRUD
- [ ] 3.1.3 Implement profile create/edit form
- [ ] 3.1.4 Add port multi-select with common port presets
- [ ] 3.1.5 Add sweep_modes checkbox group
- [ ] 3.1.6 Implement profile delete with usage warning

### 3.2 Sweep Groups UI
- [ ] 3.2.1 Create `SweepGroupsComponent` for group list
- [ ] 3.2.2 Implement group create/edit form
- [ ] 3.2.3 Add interval picker component (5m, 15m, 30m, 1h, 2h, 6h, 12h, 24h)
- [ ] 3.2.4 Add cron expression builder (optional)
- [ ] 3.2.5 Create visual query builder component for targeting
- [ ] 3.2.6 Implement live target count preview
- [ ] 3.2.7 Add partition/agent selectors
- [ ] 3.2.8 Implement group enable/disable toggle
- [ ] 3.2.9 Add "Run Now" action button

### 3.3 Sweep Group Detail View
- [ ] 3.3.1 Create group detail page with tabs
- [ ] 3.3.2 Implement "Target Devices" tab with device list
- [ ] 3.3.3 Implement "Execution History" tab
- [ ] 3.3.4 Add execution detail modal with host results
- [ ] 3.3.5 Implement group deletion with confirmation

### 3.4 Active Scans Dashboard
- [ ] 3.4.1 Create `ActiveScansComponent` for running scans
- [ ] 3.4.2 Add real-time progress indicators via PubSub
- [ ] 3.4.3 Show recent completions with success/failure badges
- [ ] 3.4.4 Add aggregate statistics cards

---

## Phase 4: Device Inventory Integration

### 4.1 Bulk Actions
- [ ] 4.1.1 Add "Add to Sweep Group" bulk action to device list
- [ ] 4.1.2 Create sweep group selector modal
- [ ] 4.1.3 Add "Create New Group" option in modal
- [ ] 4.1.4 Implement adding selected devices as static_targets

### 4.2 Device Detail Panel
- [ ] 4.2.1 Add "Sweep Status" section to device detail
- [ ] 4.2.2 Show groups targeting this device
- [ ] 4.2.3 Show last sweep results (availability, ports)
- [ ] 4.2.4 Add link to group detail from device

### 4.3 Filters
- [ ] 4.3.1 Add "Has Sweep Group" filter to device list
- [ ] 4.3.2 Add "Sweep Status" filter (available, unavailable, never swept)

---

## Phase 5: Agent Integration

### 5.1 Config Polling
- [ ] 5.1.1 Update agent to call `GetConfig` with "sweep" type
- [ ] 5.1.2 Implement config hash comparison for change detection
- [ ] 5.1.3 Apply gateway config to sweeper dynamically
- [ ] 5.1.4 Add configurable poll interval (default: 60s)
- [ ] 5.1.5 Implement file-based fallback when gateway unavailable

### 5.2 Remove KV/DataSvc Dependencies
- [ ] 5.2.1 Remove KV store config watching from sweeper
- [ ] 5.2.2 Remove datasvc client from agent sweep service
- [ ] 5.2.3 Update agent config loading priority: gateway > file > default

---

## Phase 6: Results Flow

### 6.1 Agent Push
- [ ] 6.1.1 Ensure sweep results include device metadata from config
- [ ] 6.1.2 Add sweep group ID to result payloads
- [ ] 6.1.3 Implement chunked streaming for large result sets
- [ ] 6.1.4 Add execution start/completion events

### 6.2 Gateway Forwarding
- [ ] 6.2.1 Implement sweep results extraction in gateway
- [ ] 6.2.2 Add RPC call to core-elx for results processing
- [ ] 6.2.3 Implement result buffering when core unavailable
- [ ] 6.2.4 Add metrics for results forwarding

### 6.3 Core Processing
- [ ] 6.3.1 Create `SweepResultsIngestor` module in core
- [ ] 6.3.2 Match hosts to devices by IP via DIRE
- [ ] 6.3.3 Update `ocsf_devices.is_available` from sweep results
- [ ] 6.3.4 Add "sweep" to discovery_sources array
- [ ] 6.3.5 Create device records for new hosts (type_id=0)
- [ ] 6.3.6 Update `SweepGroupExecution` status and stats
- [ ] 6.3.7 Store `SweepHostResult` records

---

## Phase 7: Testing & Documentation

### 7.1 Tests
- [ ] 7.1.1 Unit tests for TargetCriteria DSL parser
- [ ] 7.1.2 Unit tests for SweepCompiler
- [ ] 7.1.3 Integration tests for config distribution flow
- [ ] 7.1.4 LiveView tests for Settings > Networks
- [ ] 7.1.5 E2E test for sweep group → agent config → results

### 7.2 Documentation
- [ ] 7.2.1 Update admin guide with Networks settings
- [ ] 7.2.2 Document sweep group configuration options
- [ ] 7.2.3 Document device targeting criteria syntax
- [ ] 7.2.4 Add troubleshooting guide for sweep issues
