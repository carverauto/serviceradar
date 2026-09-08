# Change: Add Teleport-like agent-routed access

## Archival Reconciliation
Before archival, this change is narrowed to the delivered generic session, authorization, route, user-present SSH, custody, audit, and recording substrate. File transfer, application/TCP access, automatic host-key observation, packaged SSH CA access, production eBPF attachment, provider-native Proxmox consoles, QEMU graphical consoles, and RDP remain owned by their separate active changes and are not claimed as delivered by this foundation. Provider metadata alone does not make a console ready.

## Why
ServiceRadar needs a Teleport-like access plane built into its existing agent/gateway architecture. Operators should be able to reach infrastructure in segmented, remote, and overlapping networks through enrolled agents, with the same class of capabilities Teleport provides: SSH and shell access, session lifecycle and recording, audit trails, approval/RBAC, app/database/Kubernetes/desktop-style protocol adapters over time, and enhanced host telemetry such as BPF-backed command, file, and network tracing.

The earlier Proxmox console work motivated the outbound route shape, but does not prove a ready provider-native console transport. The generic tunnel and terminal substrate should become a broader access platform without storing high-blast-radius private keys in the control-plane database by default.

## What Changes
- Define a generic remote-access session model routed from browser to web-ng to agent-gateway to selected agent to target.
- Deliver the generic adapter boundary and SSH foundation first; Proxmox/vSphere console, RDP, and deferred OT/industrial protocols such as CEA-852/CN-IP require separate approved changes and live proofs.
- Define credential custody modes: short-lived SSH certificates as the enterprise default, user-present session credentials as a transitional fallback, and tightly scoped centrally brokered secrets only for explicit break-glass or non-SSH-device cases.
- Add RBAC, approval, audit, network scope, session lifecycle, and optional recording/redaction requirements; enhanced host-event tracing remains in its separate active change.
- Inventory Teleport functionality and reuse verified Apache-2.0 Go code wherever its full transitive dependency path is license-clean.
- Define clean-room and proposal gates for Teleport-equivalent features whose implementation source is AGPL or otherwise unsuitable for import; production BPF/enhanced recording remains in its separate active change.
- Keep browser terminal/rendering components generic, with provider/protocol-specific labels and adapters outside the core tunnel.

## Current Phase
The first SSH/proxy/recording substrate pass is implemented, along with several ServiceRadar-native hardening primitives: credential custody boundaries, route-bound grants, access-request records, host-key lifecycle primitives/UI, replay event plumbing/UI, SSH CA library/policy/smoke-test primitives, and an initial enhanced-recording boundary. The SSH CA signer is not packaged or enabled by this change, and no live target trust is claimed.

That does not mean ServiceRadar has recreated Teleport. The completed work is a foundation for Teleport-like access, not full feature parity. Full parity remains a feature-by-feature backlog covering protocol breadth, enterprise identity governance, session collaboration/moderation, production recording depth, operational hardening, and ecosystem integrations.

Certificate-first enterprise SSH remains the target of the separate SSH-enablement change. This archived foundation delivers user-present custody; centrally brokered secrets are policy-owned exceptions that require approval, a trusted credential rule, and a scoped session grant before any selected agent receives credential material.

## Impact
- Affected specs: edge-architecture, agent-connectivity, rbac-route-protection
- Affected code: web-ng remote access UI/API, agent-gateway control stream routing, Go agent remote access adapters, credential rules/broker, audit resources, console/xterm React components, future app/database/Kubernetes/desktop/RDP renderers or adapters, host tracing/BPF collector components
