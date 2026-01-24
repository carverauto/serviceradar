# Change: Fix TCP Ports Missing from Device-Based Sweep Targets

## Why

We merged the agent-side `device_targets` parsing change from #2425, but the issue persists. In #2477, the agent still logs `configuredPorts:[]` and `tcpTargets:0` even though the sweep profile has TCP ports configured and `globalSweepModes` includes `"tcp"`. ICMP scans run, but no TCP targets are generated.

This indicates the compiled sweep config reaching the agent is missing ports (or they are being overridden to empty), so the sweeper has nothing to scan for TCP.

**Updated Root Cause (hypothesis)**: The sweep compiler/config distribution path is producing an empty `ports` array for device-targeted sweeps, likely due to:
- `ports` overrides being saved as an empty list (overriding the profile),
- profile inheritance not being applied for device-targeted groups,
- or compiled config omitting ports under certain merge paths.

**GitHub Issues**: #2425 (original), #2477 (current)

## What Changes (Updated)

### Sweep Config Compilation (Core)
- Ensure `ports` are always populated when TCP modes are enabled
- Treat empty group-level port overrides as “inherit from profile”
- Add explicit validation/logging when TCP mode is enabled but no ports are configured

### Agent Visibility / Diagnostics
- Add logging in the sweep config pipeline (compiler + agent apply) to surface:
  - ports count
  - whether ports were inherited or overridden
  - TCP mode with empty ports (error/warn)

### Optional UI Guardrails (Web-NG)
- If a sweep group inherits from a profile, avoid sending empty ports overrides
- Surface a warning if TCP mode is selected but no ports are configured

## Impact

- Affected specs: `sweep-jobs`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/sweep_compiler.ex` - Ensure ports inheritance + validation
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex` - Optional diagnostics around compiled sweep config
  - `web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index.ex` - Prevent empty ports overrides (if relevant)
  - `pkg/agent/sweep_config_gateway.go` / `pkg/sweeper/sweeper.go` - Ensure TCP targets only skipped with explicit warning when ports empty
