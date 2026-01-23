# Change: Fix TCP Ports Missing from Device-Based Sweep Targets

## Why

When sweep jobs use `in:devices` targeting (device-based rather than network-based), TCP ports configured in the sweep profile are not being applied to targets. The agent logs show `configuredPorts:[]` and `tcpTargets:0` even when TCP ports 80, 443, 8080 are configured in the sweep profile. ICMP scans work correctly, but TCP port scans produce no targets.

**Root Cause**: The `gatewaySweepGroup` struct in `pkg/agent/sweep_config_gateway.go` is missing the `device_targets` field. When the gateway sends sweep configuration with device-based targets, the device targets data is dropped because there's no field to receive it.

**GitHub Issue**: #2425

## What Changes

### Gateway Config Parser (Go Agent)
- Add `device_targets` field to `gatewaySweepGroup` struct
- Update `parseGatewaySweepConfig()` to populate `SweepConfig.DeviceTargets` from gateway payload
- Ensure TCP ports from the sweep profile are available for device-targeted sweeps

### Data Flow Fix
The fix ensures the complete data flow works:
1. Gateway sends device targets with sweep modes via `in:devices` query
2. Agent parses gateway config **including** `device_targets` field (currently missing)
3. `SweepConfig.DeviceTargets` is populated with device-specific configs
4. `generateTargets()` processes `DeviceTargets` and creates TCP targets using profile ports
5. Result: Both ICMP and TCP targets are generated correctly

## Impact

- Affected specs: `sweep-jobs` (restores intended behavior per existing requirements)
- Affected code:
  - `pkg/agent/sweep_config_gateway.go` - Add device_targets field and parsing
  - `pkg/agent/types.go` - Verify DeviceTargets struct compatibility
  - `pkg/agent/sweeper.go` - Verify target generation uses device targets correctly
  - `cmd/agent/server.go` - Verify buildSweepModelConfig passes device targets
