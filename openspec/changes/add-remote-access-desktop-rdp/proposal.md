# Change: Add remote access desktop and RDP adapters

## Why
ServiceRadar needs graphical desktop access for Windows hosts and other desktop targets in the same agent-routed access plane as SSH, file transfer, application, database, and Kubernetes access.

RDP is not a terminal protocol. It introduces screen capture, clipboard, drive, printer, audio, smart-card redirection, high-bandwidth streams, and target-login credential risks. A naive implementation can become a shared-admin desktop tunnel or an exfiltration channel.

## What Changes
- Add registered desktop/RDP targets routed through selected ServiceRadar agents.
- Start with Windows RDP targets; reserve the model for future desktop protocols only after separate review.
- Add a graphical renderer path separate from xterm terminal sessions.
- Add an authenticated device-details launch flow that resolves exactly one
  authorized, enabled desktop target for the current inventory device.
- Add deployable ICE/TURN configuration with non-secret endpoint metadata,
  existing-Secret-only TURN REST key custody, and per-session credentials with
  a maximum one-hour lifetime.
- Disable clipboard, drive, printer, audio, smart-card, and file redirection by default, with per-feature RBAC and policy gates.
- Add credential-custody modes that avoid shared master accounts: domain-backed actor identity where possible, memory-only per-session user credentials when explicitly enabled, or tightly scoped brokered fallback secrets.
- Add frame/bitrate quotas, resolution policy, session timeout, approval, recording, watermark/consent policy, and forced termination behavior.
- Keep current Teleport desktop/RDP code as reference only because the current `lib/srv/desktop` dependency graph has AGPL transitive paths.

## Impact
- Affected specs: `edge-architecture`
- Affected code: web-ng graphical remote-access UI, core remote-access target/session/policy/audit resources, agent-gateway routing, Go agent desktop/RDP adapters, RBAC catalog, recording storage, demo fixtures.
