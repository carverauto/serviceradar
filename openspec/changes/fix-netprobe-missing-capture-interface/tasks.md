## 1. netprobe (this PR)
- [x] 1.1 Resolve configured `capture_interfaces` against the host's interfaces at
      startup; open capture handles and attach TC/XDP/AF_XDP only on present ones
- [x] 1.2 Report `STATUS_DEGRADED` from AddonService `Health` with a bounded reason
      and `capture_interfaces.{missing,active,available}` details
- [x] 1.3 Keep restart-required checks on the requested list (regression test)

## 2. Agent (this PR)
- [x] 2.1 Attach manager queries AddonService `Health` after a successful liveness
      probe; map `DEGRADED` to sidecar state `degraded` with the reason
- [x] 2.2 Count a degraded netprobe as running for capability reporting
- [x] 2.3 Report the systemd unit state instead of the IPC error when the unit is
      not running
- [x] 2.4 Map `Result=start-limit-hit` to `circuit_open`; skip reinstall of an
      unchanged assignment whose unit is circuit-open
- [x] 2.5 `reset-failed` the primary unit before `enable --now` / `restart`

## 3. Packaging and core status (this PR)
- [x] 3.1 `StartLimitIntervalSec=300` / `StartLimitBurst=5` on the netprobe unit
- [x] 3.2 `AddonStatusIngestor` records `degraded` as active

## 4. Core assignment-time check (follow-up PR)
- [ ] 4.1 Persist the latest `host_interfaces` names per agent
- [ ] 4.2 Profile reconcile flags targets whose configured capture interfaces are
      absent from that inventory; show it on the profile and assignment views
