# Change: Expand Teleport-like remote access parity

## Why
The agent-routed remote-access foundation gives ServiceRadar SSH, route binding, credential-custody boundaries, recording primitives, and initial governance controls, but it is not a full Teleport replacement.

ServiceRadar needs a separate, reviewable backlog for broader Teleport-like parity so large protocol, identity-governance, recording, and collaboration features do not keep the SSH foundation PR open indefinitely.

## What Changes
- Track remaining Teleport-like capability gaps as separate implementation slices.
- Require each protocol adapter to define threat model, route binding, credential custody, recording/export policy, and demo proof path before code lands.
- Preserve the Apache-2.0 strategy: import only license-clean Teleport paths, use verified Apache-era source only after explicit review, and otherwise build ServiceRadar-owned clean-room implementations.

## Impact
- Affected specs: edge-architecture
- Affected code: future remote-access protocol adapters, identity governance, session collaboration, recording/search/export, enhanced recording, and protocol-specific UI surfaces
