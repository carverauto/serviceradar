# Change: Sysmon Consolidation

## Why

Currently, the platform maintains two separate system monitoring implementations:
- **sysmon-osx** (Go): Located at `cmd/checkers/sysmon-osx/`, uses `gopsutil` for macOS
- **sysmon** (Rust): Located at `cmd/checkers/sysmon/`, uses the `sysinfo` crate for Linux

This split creates maintenance overhead, duplicated logic, and inconsistent feature sets. The Go implementation already uses `gopsutil` which works cross-platform, making it the natural foundation for unification.

Additionally, the current agent configuration is rigid:
- Checkers are configured via static JSON files on each agent host
- No centralized profile management for monitoring settings
- No way to apply consistent monitoring policies across device groups
- Administrators managing hundreds/thousands of agents have no scalable configuration approach

We need both a unified library and a centralized configuration system with top-down control.

## What Changes

### 1. Core Library: `pkg/sysmon`

Create a unified Go library at `pkg/sysmon` that:
- Uses `shirou/gopsutil` as the foundation (already proven in sysmon-osx)
- Incorporates all macOS-specific logic from `pkg/checker/sysmonosx/`
- Provides identical data structures to the Rust `sysmon` for seamless backend integration
- Supports configurable metric collection (CPU, Memory, Disk, Network, Processes)
- Is embeddable directly into `serviceradar-agent` (no separate checker process)

**Migration Path**:
- Extract core collection logic from `pkg/checker/sysmonosx/service.go`
- Add Linux-specific paths and behaviors
- Maintain the `MetricSample` structure compatible with existing backends
- Deprecate and eventually remove the Rust `sysmon` checker

### 2. Agent Integration: Embedded Sysmon

Update `serviceradar-agent` to embed `pkg/sysmon`:
- Load sysmon library at agent startup (not as a separate gRPC checker)
- Fetch monitoring configuration via gRPC from `datasvc`/`core` on startup and periodically
- Support local `sysmon.json` override for:
  - Air-gapped environments
  - Ansible/automation-driven deployments
  - Testing and development
- When both remote and local configs exist, local config takes precedence (opt-out of centralized management)

**Configuration Resolution Order**:
1. Local `sysmon.json` in config directory (highest priority)
2. Profile assigned to device via tags
3. Profile assigned directly to device
4. Default system profile (lowest priority)

### 3. Configuration & UI: Sysmon Profiles

**Backend (Elixir/Ash)**:
- Create `SysmonProfile` resource following the `SweepProfile` pattern
- Fields: name, description, sample_interval, enabled_metrics, disk_paths, thresholds, etc.
- Create `SysmonProfileAssignment` for tag-based or direct device assignments
- Implement `SysmonCompiler` (following `SweepCompiler` pattern) to compile profiles into agent config JSON

**UI (web-ng)**:
- Add "Sysmon Profiles" page under Settings
- Profile CRUD: create, view, edit, delete monitoring profiles
- Preview compiled JSON before saving
- Add profile assignment UI:
  - Assign profile to specific devices
  - Assign profile to device tags (e.g., "Database Servers" tag → "High Performance" profile)
- View which devices are using which profile

**Default Profile**:
- Ship a "Default" profile that works on Linux and macOS
- Basic monitoring: CPU (10s interval), Memory (10s), Disk (30s, root filesystem)
- Cannot be deleted, can be modified by admins

### 4. Configuration Delivery

**Protocol Updates**:
- Extend `AgentConfigResponse` to include sysmon configuration
- Add `SysmonConfig` protobuf message:
  ```protobuf
  message SysmonConfig {
    bool enabled = 1;
    int32 sample_interval_ms = 2;
    repeated string disk_paths = 3;
    bool collect_cpu = 4;
    bool collect_memory = 5;
    bool collect_disk = 6;
    bool collect_network = 7;
    bool collect_processes = 8;
    map<string, string> thresholds = 9;
  }
  ```
- Agent requests config on startup via `GetConfig` RPC
- Agent periodically checks for config updates (configurable interval, default 5 minutes)

### 5. Deployment Flexibility

**Centralized (UI-managed)**:
- Admins create profiles in UI
- Assign profiles to devices/tags
- Agents automatically pick up configuration
- Changes propagate via `ConfigInvalidationNotifier`

**Distributed (filesystem-managed)**:
- Users deploy `sysmon.json` to `/etc/serviceradar/sysmon.json`
- Agent uses local config, ignores remote profiles
- Ideal for: Ansible deployments, air-gapped networks, compliance requirements

**Hybrid**:
- Use centralized for most devices
- Override specific devices via local config when needed

## Impact

### Affected Specs
- `sysmon-library` (new) - Core metrics collection library
- `agent-configuration` (new) - Config fetching and resolution
- `build-web-ui` (modified) - Profile management UI
- `agent-connectivity` (modified) - Config delivery protocol

### Affected Code
- `pkg/sysmon/` (new) - Cross-platform metrics library
- `pkg/agent/` - Embed sysmon, add config fetching
- `cmd/agent/` - Startup integration
- `proto/monitoring.proto` - SysmonConfig message
- `elixir/serviceradar_core/` - SysmonProfile resource, compiler
- `web-ng/` - Profile management LiveView pages

### Migration
- Phase 1: Create `pkg/sysmon`, embed in agent alongside existing checker support
- Phase 2: Add profile management backend and UI
- Phase 3: Deprecate standalone sysmon/sysmon-osx checkers
- Phase 4: Remove Rust sysmon checker

### Breaking Changes
- **None for existing deployments**: Existing sysmon checkers continue to work
- New embedded sysmon is opt-in until Phase 3
- Rust sysmon removal (Phase 4) will require migration to embedded sysmon
