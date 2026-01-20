# Change: Merge Dusk Checker into ServiceRadar Agent

## Why

The standalone `serviceradar-dusk-checker` binary adds deployment complexity and operational overhead. By embedding it into the agent (following the same pattern used for sysmon and SNMP), users get a single agent binary that can optionally monitor Dusk blockchain nodes. Configuration is driven through the UI and config compiler, consistent with other agent services.

## What Changes

- **Agent Integration**: Add `DuskService` to `pkg/agent/` following the `SysmonService`/`SNMPAgentService` pattern
- **Config Discovery**: Agent loads dusk config from `{configDir}/dusk.json` or receives it via the config compiler
- **Optional by Default**: Dusk monitoring is disabled unless explicitly configured through the UI
- **Cleanup Standalone**: Remove or deprecate `cmd/checkers/dusk/`, packaging artifacts, and systemd units
- **Config Compiler**: Update Elixir config compiler to generate dusk-checker configs when enabled via UI
- **Documentation**: Update agent docs to reflect embedded dusk monitoring capability

## Impact

- Affected specs: `agent-configuration`
- Affected code:
  - `pkg/agent/dusk_service.go` (new)
  - `pkg/agent/server.go` (init dusk service)
  - `pkg/agent/types.go` (add duskService field)
  - `pkg/checker/dusk/` (reuse existing implementation)
  - `cmd/checkers/dusk/` (deprecate/remove)
  - `packaging/dusk-checker/` (deprecate/remove)
  - `elixir/serviceradar_core/` (config compiler updates)
  - `web-ng/` (UI for dusk configuration)
- **BREAKING**: Standalone `serviceradar-dusk-checker` binary will be deprecated; users must migrate to agent-embedded configuration
