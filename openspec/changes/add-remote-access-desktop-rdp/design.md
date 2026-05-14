## Context
Teleport-style desktop access lets users reach private graphical sessions after SSO/RBAC checks. ServiceRadar should provide comparable access while preserving the existing agent-routed remote-access model:

```text
browser graphical renderer
  -> web-ng desktop access endpoint
  -> core policy/session/recording manager
  -> agent-gateway selected route
  -> existing agent-initiated control stream
  -> agent desktop/RDP adapter
  -> registered private RDP target
```

Desktop/RDP must not reuse terminal assumptions. It needs a renderer-specific frame protocol, explicit feature gates for redirection channels, and credential handling that does not create a shared bastion account.

## Goals
- Provide controlled browser access to registered Windows RDP targets through an edge agent.
- Preserve one actor, one access session, one selected agent/gateway route, one desktop target, one credential mode, one policy snapshot, and one audit/recording boundary.
- Keep target credentials out of persisted session metadata and browser storage.
- Disable redirection channels by default and gate every redirection feature independently.
- Enforce frame rate, bitrate, resolution, stream count, idle timeout, session TTL, and recording policy.
- Record lifecycle and metadata by default; store screen frames or clipboard data only when explicit policy enables content recording.
- Keep implementation ServiceRadar-owned unless a future exact-file Teleport vendoring review approves a small Apache-compatible utility.

## Non-Goals
- Do not provide arbitrary RDP tunneling to client-supplied hosts.
- Do not reuse xterm terminal rendering for RDP.
- Do not enable clipboard, drive, printer, audio, smart-card, or file redirection by default.
- Do not store target desktop passwords or generated credential material in session metadata.
- Do not implement VNC, SPICE, browser-native WebRTC remoting, or general screen sharing in the first slice.
- Do not copy current Teleport `lib/srv/desktop` or RDP implementation code.

## Resource Model
The first implementation should introduce a registered desktop target resource, or extend the remote-access target model, with:

- stable target ID
- display name and inventory/device relation
- protocol: `rdp` first
- selected agent or allowed agent set
- upstream host/IP and port from trusted inventory/policy
- target TLS/NLA policy and certificate trust mode
- credential mode: domain-backed SSO/delegation, memory-only per-session user credential, smart-card/client-cert auth when supported, or centrally brokered fallback secret
- allowed Windows domain or local-login principals
- screen policy: max resolution, color depth, frame rate, bitrate, idle timeout, session TTL, and resize behavior
- redirection policy: clipboard, drive, printer, audio, smart-card, file copy, and local resource redirection
- watermark, consent, and privacy notice policy
- approval, recording, retention, and export policy

## Credential Custody
ServiceRadar must not rely on a single shared desktop administrator account.

Preferred credential modes:

- Domain-backed actor identity through Kerberos constrained delegation or an equivalent enterprise SSO model where the target sees the real user.
- Smart-card or certificate-backed user authentication when the target environment supports it.
- Memory-only per-session user credentials when an enterprise requires users to enter their own domain credentials. The credentials must not be persisted and must be erased on session close, timeout, route loss, or authentication failure.

Fallback mode:

- Centrally brokered desktop credentials are allowed only for explicitly configured targets with approval, TTL, target binding, actor binding, route binding, audit metadata, and no browser exposure. This is a compatibility escape hatch, not the default enterprise posture.

The agent must not write passwords, generated keys, RDP files, or credential caches to disk.

## Rendering And Frame Protocol
RDP needs a separate graphical renderer path:

- browser renderer consumes typed frame/update messages rather than terminal byte streams
- control frames handle resize, keyboard, pointer, focus, clipboard, stream quality, and close events
- agent frames enforce max frame rate, max bitrate, max resolution, and backpressure
- browser UI makes target identity, recording status, redirection state, and approval state visible
- renderer implementation must be isolated from terminal code so future desktop protocols do not leak terminal assumptions

Dependency choice is an implementation task. Candidate RDP libraries or renderers must pass license, maintenance, platform, security, and browser compatibility review before adoption.

## Redirection And Exfiltration Controls
All desktop redirection features are disabled by default.

Controls:

- Clipboard: per-direction policy for local-to-remote and remote-to-local, max size, text-only default, binary/file denial by default, and optional content audit.
- Drive/file redirection: disabled by default; if enabled later, it must reuse the file-transfer policy surface for paths, quotas, malware scanning hooks, and audit metadata.
- Printer redirection: disabled by default; requires explicit target policy and audit metadata.
- Audio redirection: disabled by default; requires bitrate and recording interaction policy.
- Smart-card redirection: disabled by default; requires separate credential-custody review because it can become an authentication delegation path.

## Recording And Audit
Desktop access recording stores metadata by default:

- actor, session, route, target, protocol, credential mode, and selected agent
- target TLS/NLA posture and policy decisions
- screen resolution, frame rate, bitrate, byte counts, duration, and disconnect reason
- redirection feature state and per-feature policy decisions
- approval and reviewer metadata when required

Screen-frame recording, screenshots, clipboard content, transferred files, audio, and smart-card events are sensitive. Content capture requires explicit policy, visible session indicators, retention controls, RBAC, and export controls.

## Source Reuse
Current Teleport desktop access code is not approved for import:

```bash
TELEPORT_SRC=$HOME/src/teleport scripts/check-teleport-license-paths.sh \
  github.com/gravitational/teleport/lib/srv/desktop \
  github.com/gravitational/teleport/lib/srv/desktop/rdp \
  github.com/gravitational/teleport/lib/web/desktop
```

The current checkout reports AGPL transitive dependencies through Teleport API/types/auth/logging/proto and desktop protocol paths. Treat Teleport behavior as product and architecture reference only. Use ServiceRadar-owned session/policy code and separately reviewed RDP dependencies.

## Validation
- Unit tests for desktop target/resource normalization rejecting client-selected upstream hosts, ports, credentials, redirection features, routes, quotas, and recording overrides.
- RBAC and approval tests proving access and redirection features are denied without explicit permission.
- Agent adapter tests proving TLS/NLA policy, credential non-persistence, frame quotas, resize handling, backpressure, timeout, and route-loss cleanup.
- Renderer tests proving keyboard, pointer, resize, focus, and close events map to typed frames without terminal assumptions.
- Recording tests proving metadata is stored and screen/clipboard/file/audio content is not retained by default.
- Demo proof with a private Windows RDP target or controlled RDP test server reachable only from an agent.
