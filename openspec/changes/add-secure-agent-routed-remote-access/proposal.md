# Change: Add Teleport-like agent-routed access

## Why
ServiceRadar needs a Teleport-like access plane built into its existing agent/gateway architecture. Operators should be able to reach infrastructure in segmented, remote, and overlapping networks through enrolled agents, with the same class of capabilities Teleport provides: SSH and shell access, session lifecycle and recording, audit trails, approval/RBAC, app/database/Kubernetes/desktop-style protocol adapters over time, and enhanced host telemetry such as BPF-backed command, file, and network tracing.

The current Proxmox console work proves the route, but the console/xterm substrate should become a broader access platform without storing high-blast-radius private keys in the control-plane database by default.

## What Changes
- Define a generic remote-access session model routed from browser to web-ng to agent-gateway to selected agent to target.
- Support protocol adapters for SSH first, Proxmox/vSphere console targets as consumers, RDP later, and deferred OT/industrial protocol adapters such as CEA-852/CN-IP for LonTalk networks.
- Define credential custody modes: centrally brokered secret refs, agent-local credentials, user-present session credentials, and future short-lived SSH certificates/FIDO2 signing.
- Add RBAC, approval, audit, network scope, session lifecycle, optional recording/redaction, and enhanced host-event tracing requirements.
- Inventory Teleport functionality and reuse verified Apache-2.0 Go code wherever its full transitive dependency path is license-clean.
- Build clean-room ServiceRadar implementations for Teleport-equivalent features whose implementation source is AGPL or otherwise unsuitable for import, including BPF/enhanced recording if no importable path is cleared.
- Keep browser terminal/rendering components generic, with provider/protocol-specific labels and adapters outside the core tunnel.

## Impact
- Affected specs: edge-architecture, agent-connectivity, rbac-route-protection
- Affected code: web-ng remote access UI/API, agent-gateway control stream routing, Go agent remote access adapters, credential rules/broker, audit resources, console/xterm React components, future app/database/Kubernetes/desktop/RDP renderers or adapters, host tracing/BPF collector components
