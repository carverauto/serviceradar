# Tasks: Merge Dusk Checker into ServiceRadar Agent

## 1. Agent Integration

- [x] 1.1 Create `pkg/agent/dusk_service.go` following the `SysmonService` pattern
- [x] 1.2 Define `DuskServiceConfig` struct with agentID, partition, configDir, logger
- [x] 1.3 Implement `Start(ctx)` to load config and start monitoring (disabled if no config)
- [x] 1.4 Implement `Stop(ctx)` to gracefully shutdown WebSocket connections
- [x] 1.5 Implement `GetStatus(ctx)` returning `*proto.StatusResponse` with block data
- [x] 1.6 Implement config refresh loop for hot-reload support
- [x] 1.7 Add `duskService *DuskService` field to `Server` struct in `types.go`
- [x] 1.8 Add `initDuskService(ctx)` method to `server.go`
- [x] 1.9 Call `initDuskService` from `NewServer` (after sysmon/SNMP init)
- [x] 1.10 Add dusk service stop in `Server.Stop()`
- [x] 1.11 Write unit tests for `DuskService`

## 2. Config Loading

- [x] 2.1 Define dusk config file location: `{configDir}/dusk.json`
- [x] 2.2 Create `loadDuskConfig(ctx)` method that returns config + source
- [x] 2.3 Add `enabled` field to dusk config (default: false)
- [x] 2.4 Implement cache path for resilient config storage
- [x] 2.5 Add config hash computation for change detection

## 3. Config Compiler (Elixir)

- [x] 3.1 Add `DuskProfile` Ash resource in `serviceradar_core` (with SRQL targeting)
- [x] 3.2 Create `DuskCompiler` module for dusk config generation
- [x] 3.3 Add dusk config type to config distribution endpoint (`AgentConfigGenerator`)
- [x] 3.4 Ensure config is only generated when explicitly enabled (default disabled)
- [x] 3.5 Write tests for dusk config compilation

## 4. Web UI

- [x] 4.1 Add dusk checker configuration section in device/agent settings
- [x] 4.2 Create form for dusk node address, timeout settings
- [x] 4.3 Add enable/disable toggle for dusk monitoring
- [x] 4.4 Wire up save action to create/update `DuskProfile` resource

## 5. Cleanup Standalone Binary

- [x] 5.1 Remove `cmd/checkers/dusk/` directory entirely
- [x] 5.2 Remove `packaging/dusk-checker/` directory entirely
- [x] 5.3 Remove dusk-checker from Makefile targets
- [x] 5.4 Remove dusk-checker from packaging config files (packages.bzl, components.json)
- [x] 5.5 Remove dusk-checker from config registry, CLI utilities, install script
- [x] 5.6 Remove dusk-checker from .gitignore and documentation

## 6. Documentation

- [x] 6.1 Create `docs/docs/dusk-profiles.md` with comprehensive dusk monitoring documentation
- [x] 6.2 Document migration path from standalone dusk-checker to agent-embedded
- [x] 6.3 Add dusk configuration examples to documentation
- [x] 6.4 Update `CHANGELOG` with dusk integration notes

## 7. Testing & Validation

- [x] 7.1 Integration test: agent starts with dusk disabled (no config)
- [x] 7.2 Integration test: agent starts with dusk enabled (valid config)
- [x] 7.3 Integration test: dusk config hot-reload
- [x] 7.4 E2E test: UI creates dusk config, agent picks it up (manual verification)
- [x] 7.5 Verify dusk status appears in agent push payloads
