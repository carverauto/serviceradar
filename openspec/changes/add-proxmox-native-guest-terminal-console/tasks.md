## 1. Proposal and Compatibility Contract

- [ ] 1.1 Approve this proposal and identify a dedicated non-production LXC and serial-enabled QEMU canary in each intended cluster.
- [ ] 1.2 Record supported PVE versions, authentication modes, terminal endpoint variants, and minimum provider privileges in an operator compatibility matrix.
- [ ] 1.3 Define typed LXC and QEMU serial-console broker/open/resize/data/close contracts and explicit unavailable/error codes.
- [ ] 1.4 Add contract fixtures for successful terminal tickets, malformed responses, expired tickets, unsupported graphical-only guests, and provider TLS errors.

## 2. Trusted Guest Admission and Session Policy

- [ ] 2.1 Build a trusted guest-terminal target snapshot from canonical virtualization inventory with cluster, node, VMID, guest kind, freshness, and uniqueness evidence.
- [ ] 2.2 Reject unresolved aliases, duplicate candidates, stale/disabled inventory, missing device links, and client-supplied provider routing fields before credential resolution.
- [ ] 2.3 Extend the existing console/session policy to bind guest target, selected agent, partition, route, credential-rule reference, and terminal-only capability.
- [ ] 2.4 Require explicit console permission before returning any availability or target detail to the caller.
- [ ] 2.5 Emit redacted lifecycle audit events and session outcomes with provider-console custody metadata and no terminal/ticket/secret content.

## 3. Edge Proxmox Guest Terminal Adapter

- [ ] 3.1 Implement a selected-agent native Proxmox terminal adapter for LXC and QEMU serial console targets only.
- [ ] 3.2 Resolve the session-scoped provider credential grant only after target/route admission; request the provider ticket and connect its websocket in agent memory.
- [ ] 3.3 Enforce configured PVE TLS server identity and CA policy; fail closed on certificate/name/trust errors.
- [ ] 3.4 Translate only bounded terminal data, resize, heartbeat, close, and normalized error frames through the existing remote-access tunnel.
- [ ] 3.5 Zero/clear grant and ticket buffers on every close, timeout, route-loss, cancellation, and adapter error path.
- [ ] 3.6 Reject graphical VNC/noVNC/SPICE/RFB, arbitrary provider endpoints, unsupported guest kinds, and unbounded provider frames.
- [ ] 3.7 Add adapter capability probing so unsupported PVE/guest combinations remain unavailable rather than failing after browser attach.

## 4. Browser and Device-Details Experience

- [ ] 4.1 Surface the guest terminal action only for authorized, uniquely linked, supported LXC/QEMU targets with a ready selected agent capability.
- [ ] 4.2 Reuse the existing xterm remote-console component with visible target identity, terminal-only/provider-console notice, session state, and safe unavailable reasons.
- [ ] 4.3 Verify browser attach tickets remain short-lived and single-use and that the browser never receives a PVE address, credential, cookie, or provider ticket.

## 5. Tests and Live Proof

- [ ] 5.1 Add control-plane tests for RBAC, tenant/partition/agent/route binding, identity ambiguity, stale inventory, and audit redaction.
- [ ] 5.2 Add agent tests for PVE ticket/websocket contract parsing, TLS trust, frame limits, resize, expiration, route loss, and in-memory cleanup.
- [ ] 5.3 Add end-to-end tunnel tests proving a terminal opens only to the policy-selected LXC/QEMU target and cannot be retargeted by browser frames.
- [ ] 5.4 After release rollout, recover one console assignment through the partition-reapproval flow and prove inventory stability separately for Farm01 and Tonka01.
- [ ] 5.5 Run the first live LXC and serial-QEMU canaries through ServiceRadar, validate terminal I/O/resize/close/audit, and prove ticket/TLS/identity failures fail closed.
- [ ] 5.6 Keep graphical guest-console and Windows desktop actions disabled; update the RDP/graphical-console follow-up only after its independent live proof passes.

## 6. Documentation and Completion

- [ ] 6.1 Document least-privilege PVE console credentials, required serial-console guest configuration, supported versions, recovery, and rollback.
- [ ] 6.2 Update the remote-access capability matrix and device-details operator guidance with terminal-only scope and graphical-console exclusion.
- [ ] 6.3 Run focused Go/Elixir/Bazel/OpenSpec validation and publish reviewer evidence.
- [ ] 6.4 Obtain review/approval, deploy only after all live canaries pass, then archive through a separate OpenSpec change.
