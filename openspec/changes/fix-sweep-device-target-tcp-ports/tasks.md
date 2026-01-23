# Tasks: Fix TCP Ports Missing from Device-Based Sweep Targets

## 1. Investigation & Verification
- [x] 1.1 Verify gateway is sending `device_targets` in sweep config payload
- [x] 1.2 Confirm `gatewaySweepGroup` struct is missing `device_targets` field
- [x] 1.3 Trace data flow from gateway config to sweeper target generation

## 2. Implementation
- [x] 2.1 Add `DeviceTargets` field to `gatewaySweepGroup` struct in `sweep_config_gateway.go`
- [x] 2.2 Add `gatewayDeviceTarget` struct matching gateway payload format
- [x] 2.3 Update `parseGatewaySweepConfig()` to populate `SweepConfig.DeviceTargets`
- [x] 2.4 Add `convertDeviceTargets()` function to convert gateway format to model format
- [x] 2.5 Verify `buildSweepModelConfig()` passes device targets to sweeper (confirmed at line 130)
- [x] 2.6 Update log message in `applySweepConfig` to include device targets count

## 3. Testing
- [x] 3.1 Add unit test for `parseGatewaySweepConfig` with device targets
- [x] 3.2 Add unit test for empty/missing device targets (backward compatibility)
- [x] 3.3 Add unit test for `convertDeviceTargets` IP normalization
- [ ] 3.4 Test sweep job with `in:devices` targeting and TCP ports configured (manual/integration)
- [ ] 3.5 Verify agent logs show correct `configuredPorts` and `tcpTargets > 0` (manual)
- [ ] 3.6 Test mixed ICMP + TCP sweep modes work together (manual)

## 4. Verification
- [ ] 4.1 Verify ICMP targets still work (regression test - manual)
- [ ] 4.2 Verify TCP targets are created for each configured port (manual)
- [ ] 4.3 Verify sweep results report correct host counts (manual)

## Files Modified
- `pkg/agent/sweep_config_gateway.go` - Added `DeviceTargets` field and `convertDeviceTargets()` function
- `pkg/agent/sweep_config_gateway_test.go` - New test file with unit tests
- `pkg/agent/push_loop.go` - Enhanced logging to include device targets count
