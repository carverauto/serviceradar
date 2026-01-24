# Tasks: Fix TCP Ports Missing from Device-Based Sweep Targets

## 0. Context (already merged, but insufficient)
- [x] 0.1 Agent parses `device_targets` from gateway payload (merged from #2425)
- [x] 0.2 Added unit tests for `parseGatewaySweepConfig` device targets
- [x] 0.3 Enhanced agent logging to show device target counts

## 1. Investigation & Repro (updated)
- [x] 1.1 Capture compiled sweep config for affected agent and confirm `ports`/`modes` in payload
- [ ] 1.2 Verify SweepCompiler output for `in:devices` groups includes profile ports
- [x] 1.3 Check whether group ports are being saved as an empty override or profile_id is unset
- [x] 1.4 Confirm ports are not dropped between compiler output and agent config apply

## 2. Implementation (updated)
- [x] 2.1 Treat empty group-level ports as “inherit from profile” in SweepCompiler
- [x] 2.2 Guardrail: if TCP mode enabled but ports empty, log + drop TCP mode (or fail compile)
- [ ] 2.3 Optional UI guardrail: avoid sending empty port overrides; warn when TCP enabled without ports

## 3. Tests
- [x] 3.1 SweepCompiler test: profile ports preserved when group ports nil/empty
- [x] 3.2 Integration test: agent config payload includes ports for device-targeted group
- [ ] 3.3 Agent test: TCP targets generated when ports present; warning emitted when ports empty

## 4. Verification
- [ ] 4.1 Reproduce #2477 and verify `configuredPorts` populated and `tcpTargets > 0`
- [ ] 4.2 Verify ICMP still works and TCP scans run with configured ports
