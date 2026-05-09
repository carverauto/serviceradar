# Change: Add secure agent-routed remote access

## Why
ServiceRadar needs a secure, generic remote-access layer that lets operators reach devices in segmented, remote, and overlapping networks through enrolled agents. The current Proxmox console work proves the path, but the console/xterm substrate should support plain SSH, hypervisor consoles, and future RDP without storing high-blast-radius private keys in the control-plane database by default.

## What Changes
- Define a generic remote-access session model routed from browser to web-ng to agent-gateway to selected agent to target.
- Support protocol adapters for SSH first, Proxmox/vSphere console targets as consumers, RDP later, and deferred OT/industrial protocol adapters such as CEA-852/CN-IP for LonTalk networks.
- Define credential custody modes: centrally brokered secret refs, agent-local credentials, user-present session credentials, and future short-lived SSH certificates/FIDO2 signing.
- Add RBAC, approval, audit, network scope, session lifecycle, and optional recording/redaction requirements.
- Keep browser terminal/rendering components generic, with provider/protocol-specific labels and adapters outside the core tunnel.

## Impact
- Affected specs: edge-architecture, agent-connectivity, rbac-route-protection
- Affected code: web-ng remote access UI/API, agent-gateway control stream routing, Go agent remote access adapters, credential rules/broker, audit resources, console/xterm React components, future RDP renderer/adapters
