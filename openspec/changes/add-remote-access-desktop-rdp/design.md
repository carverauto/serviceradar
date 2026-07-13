## Context
Teleport-style desktop access lets users reach private graphical sessions after SSO/RBAC checks. ServiceRadar should provide comparable access while preserving the existing agent-routed remote-access model:

```text
browser graphical renderer
  -> web-ng desktop access endpoint
  -> core policy/session/recording manager
  -> agent-gateway selected route
  -> existing agent-initiated control stream for lifecycle/control
  -> dedicated desktop media stream for high-volume screen updates
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
- agent and gateway media frames enforce max frame rate, max bitrate, max resolution, credit windows, and backpressure
- browser UI makes target identity, recording status, redirection state, and approval state visible
- renderer implementation must be isolated from terminal code so future desktop protocols do not leak terminal assumptions

Dependency choice is an implementation task. Candidate RDP libraries or renderers must pass license, maintenance, platform, security, and browser compatibility review before adoption.

## Browser Delivery And Rendering
The browser path should reuse the ServiceRadar media/data-plane lessons without forcing RDP pixels into the topology data model.

Golden path:

```text
web-ng desktop session endpoint
  -> WebRTC desktop media session
  -> binary desktop media frame envelope
  -> browser worker / WASM helper for parsing, region state, and backpressure
  -> WebCodecs video surface or WebGPU dirty-region renderer
```

Use the camera relay browser path as the closest transport precedent:

- WebRTC signaling and peer lifecycle through web-ng/core-elx, modeled after the camera relay WebRTC path
- WebRTC media tracks for encoded video payloads when the adapter can produce a browser-decodable stream
- WebRTC DataChannel for dirty rectangles, tiles, cursor updates, browser backpressure, quality control, and low-latency input/control frames
- small fixed binary headers before large payload bytes
- browser capability negotiation
- decoder queue/backpressure checks
- stale-frame drop/coalescing rather than unbounded buffering

Do not add a browser binary WebSocket media fallback for desktop screen payloads. A second browser media transport creates avoidable policy, recording, backpressure, and test surface. WebSockets may still be used for WebRTC signaling, status snapshots, or non-media control where the existing web-ng patterns already use them.

The first renderer should support two payload families:

- Encoded video frames for paths where the adapter can produce H264, AV1, VP9, or another browser-decodable codec. Prefer WebRTC media tracks into a browser video surface; use WebCodecs only for non-track decoded frame paths.
- Dirty rectangle or tile updates for administrative desktop workloads where changed regions are small. Carry these over WebRTC DataChannel and prefer WebGPU texture updates when available, with Canvas2D reserved for early local harnesses only.

Use the God View/topology zero-copy pattern selectively:

- WASM is appropriate for parsing binary envelopes, maintaining region/tile state, computing masks, applying policy-safe transforms, and preparing GPU upload descriptors.
- WebGPU is appropriate for applying dirty rectangles or tiles directly into a desktop texture and compositing cursors, watermarks, and recording indicators.
- Roaring bitmaps may be used for dirty tile sets or changed-region masks when a fixed tile grid is selected.
- Apache Arrow IPC should be reserved for structured metadata, audit/stat snapshots, overlay data, or optional frame manifests. It is not the primary screen-pixel transport because RDP screen payloads are dense image/video data rather than columnar analytical rows.

The browser renderer must not receive target credentials, brokered secrets, RDP files, or connection details that would let it bypass ServiceRadar routing. It receives only a session-bound media token, display policy, target label/identity, visible recording/redirection state, and renderable frame payloads.

## Device Launch And ICE/TURN Runtime

The device-details RDP action must resolve targets server-side from the exact
inventory `device_uid`. The browser may submit only the selected registered
desktop-target ID, protocol, adapter, an optional approval ID, and the user's
own target username/password. It must not submit an upstream address, route,
TLS policy, CA bundle, redirection policy, or broker credential reference.

The launcher keeps the authenticated remote-access WebSocket alive while the
WebRTC viewer exists. It waits for the route-bound `ready` outcome before
creating the WebRTC viewer, clears the password from component state as soon as
attach succeeds, and closes both WebRTC and remote-access sessions on failure
or unmount.

ICE/TURN is deployment policy, not per-target or browser input:

- ICE server endpoints are a bounded JSON list containing only `stun:`,
  `stuns:`, `turn:`, or `turns:` URLs. Embedded usernames, passwords, userinfo,
  arbitrary URI schemes, and malformed ports are rejected at runtime.
- TURN uses the standard REST shared-secret mechanism. The shared secret is
  read only from one operator-owned Kubernetes Secret file mounted into
  web-ng; it is never accepted in Helm values, an environment variable, target
  state, or browser input.
- Web-ng mints a distinct HMAC credential for each viewer/session. The
  time-bound username includes its expiry and a session/actor binding, and its
  TTL is positive and no greater than one hour.
- The browser receives only the minted username/credential and public TURN
  endpoint. The shared secret never leaves the web-ng process and is not
  returned, logged, or persisted in remote-access records.
- Helm must fail rendering when TURN endpoints are enabled without an existing
  Secret reference, when the Secret key is absent, or when the requested TTL is
  outside the supported range.
- Deployments with namespace-wide default-deny egress use a separate additive
  `Egress` NetworkPolicy selecting only `app: serviceradar-core`, because the
  core-elx data-channel provider owns the ExWebRTC PeerConnection and originates
  ICE traffic; web-ng is only its ERTS RPC signaling client. The policy is
  opt-in, requires the chart-wide NetworkPolicy and RDP to be enabled, and
  accepts only explicit IPv4/IPv6 CIDRs and bounded UDP/TCP ports. It rejects
  DNS names, empty destination/port lists, malformed values, and catch-all
  CIDRs rather than granting ICE egress to every ServiceRadar workload or all
  destinations. If the chart's ordered Calico log-and-deny policy is active,
  the new template also renders an equivalent core-only Calico `Allow` at the
  immediately higher priority so that the existing final deny remains effective
  for every other destination, port, and workload.

STUN-only deployments remain possible where public server-reflexive candidates
are reachable. Operators should configure TURN for restrictive NAT/firewall
environments and for reliable production access.

## Transport Strategy
The existing agent control stream is appropriate for session lifecycle and low-rate control events. It is not the production transport for 1080p or high-frame-rate graphical updates.

Use the control stream for:

- `open`, `ready`, `close`, `error`, heartbeat, and outcome frames
- target policy snapshot delivery
- credential grant delivery
- keyboard, pointer, resize, focus, clipboard-policy decisions, and quality-control messages
- revocation, approval changes, and forced termination

Use a dedicated desktop media stream for:

- screen update chunks
- cursor bitmap updates
- frame metadata and timing
- stream byte counters
- browser/gateway backpressure acknowledgements

The preferred implementation path is to reuse the shape of the existing camera media relay pipeline instead of creating an unrelated transport stack:

```text
agent desktop media gRPC
  -> agent-gateway admission/session tracker
  -> ERTS RPC forwarder
  -> core-elx/web-ng ingress
  -> browser renderer channel
```

This should be a desktop-specific media service or a carefully generalized media service, not an overload of camera source/profile semantics. Reuse the proven pieces: edge-facing gRPC admission, gateway session tracking, chunk limits, heartbeat/lease handling, ERTS forwarding into core, and explicit close semantics.

Desktop differs from camera media in two important ways:

- camera media is mostly agent-to-core upload, while desktop requires browser-to-agent feedback for quality, pause/resume, input, and close
- camera viewers can tolerate streaming latency, while desktop interactivity needs tighter backpressure and faster quality downshift

For that reason, the desktop media path should either be bidirectional gRPC or paired upload/control RPCs with explicit credit acknowledgements. The control stream can carry low-rate input/control during early implementation, but production screen flow control must be tied to the media stream so the agent can stop reading from the Rust helper when browser or gateway buffers are full.

Devolutions Gateway provides useful precedent for this split without requiring us to adopt its whole relay stack. Its agent tunnel separates control traffic from per-session streams, JMUX uses channel windows and packet limits, JET uses short-lived association tokens, and its traffic-audit path records terminal stream metadata. ServiceRadar should mirror those architectural properties in project-owned APIs and implementation unless a later exact-file review approves importing a specific compatible crate.

The first compatibility wrapper may carry small JSON desktop frames inside `Monitoring.ConsoleFrame` while the adapter shape is being proven. Production screen traffic must move to a dedicated stream before `remote_access.rdp` is advertised as an operational capability. The dedicated stream should be bidirectional so the gateway can send credit-window, quality, pause/resume, and close signals without waiting for a separate control-stream round trip.

### Why A Dedicated Stream
RDP screen traffic is bursty and potentially large. Even when RDP sends changed regions rather than full frames, a busy desktop can produce many updates per second. Sending that through the generic control stream would couple desktop rendering to unrelated agent control messages such as commands, config pushes, heartbeats, SSH console traffic, and file-transfer control frames.

Risks of using the generic control stream for production screen data:

- head-of-line blocking for command/config/control traffic
- large BEAM PubSub messages and process mailboxes under frame bursts
- weak browser backpressure feedback
- hard-to-enforce per-session byte and frame budgets
- difficult separation between metadata recording and sensitive screen content
- worse failure isolation when a desktop session misbehaves

### Stream Shape
The dedicated desktop stream should be session-scoped and route-bound:

```text
control stream:
  gateway -> agent: open session with trusted target policy and credential grant
  agent -> gateway: ready with desktop_media_session_id and max_chunk_bytes

desktop media stream:
  agent <-> gateway: DesktopMediaFrame / DesktopMediaAck
  gateway <-> web-ng/browser channel: renderable frame chunks and backpressure
```

Frame chunks should carry:

- `session_id`
- `media_session_id`
- `sequence`
- frame/update type
- width, height, pixel format or encoding
- dirty-region metadata where available
- payload bytes
- keyframe/full-frame marker when applicable
- byte count and timestamp

Browser media frames should use a compact binary envelope rather than JSON or Arrow IPC for screen payloads. The envelope should identify payload family (`video`, `dirty_rect`, `tile`, `cursor`, or `metadata`), codec/encoding, display dimensions, dirty region or tile metadata, sequence, keyframe/full-frame state, and timestamps. Payload bytes remain separate from the structured header so WebRTC DataChannel/browser workers can transfer buffers without unnecessary copies.

Acknowledgements should carry:

- last accepted sequence
- remaining credit bytes or frames
- target quality level when downshifting
- pause/resume/close reason

The agent must stop reading from the Rust RDP helper, lower quality, or close the session when the gateway/browser credit window is exhausted.

The first implementation should make flow control explicit rather than implicit in queue depth. Model it like a channel window:

- the receiver grants an initial byte/frame window
- every media chunk consumes credit
- the receiver sends window adjustments as chunks are accepted by the next hop
- the sender never exceeds the lesser of remaining credit and max chunk size
- EOF and close remain deliverable even when no media credit remains
- stale non-keyframe updates may be coalesced or dropped when quality is downshifted

### Local Go/Rust Boundary
The agent-side Rust helper can still communicate with the Go agent over local stdio or a Unix-domain socket. That boundary is inside the agent host and should use length-prefixed binary frames, not JSON, for screen payloads. JSON remains acceptable for policy and low-rate control envelopes. The Go agent remains the policy, route, credential, and audit owner; the Rust helper remains the RDP protocol engine.

Start one helper process per RDP session. This gives clear credential lifetime, crash isolation, and cleanup behavior. A warm helper pool can be considered later only if startup time or session density becomes a measured problem.

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

## Teleport-Style Desktop Parity Status

This change is tracking comparable product behavior, not source-code parity with
Teleport. Current Teleport desktop/RDP implementation code remains reference-only
under the source-reuse rules above.

| Capability | ServiceRadar status | Notes |
| --- | --- | --- |
| Registered desktop targets | Implemented | Sessions are created from trusted target IDs and policy snapshots, not browser-supplied upstreams. |
| Route-bound agent access | Implemented | Desktop sessions bind to one selected agent/gateway route and reject mismatched route, media, and control frames. |
| RBAC and approval binding | Implemented | RDP uses `devices.remote_access.rdp.open` and approval metadata binds target, route, credential mode, and policy. |
| Credential custody | Partial | Memory-only user credentials and brokered-secret policy guards are implemented. Domain delegation and smart-card modes remain design targets. |
| TLS/NLA enforcement | Partial | The helper validates policy, builds verified Rustls client configs from registered CA/system roots, reaches TLS/CredSSP boundaries in probes, and keeps NLA required. Full live CredSSP authentication is still gated. |
| Desktop media transport | Implemented | Dedicated desktop media gRPC, gateway tracking, ERTS forwarding, WebRTC DataChannel delivery, SRDP envelopes, credits, pause/resume, quality hints, and close semantics are implemented and tested. |
| Browser renderer | Partial | WebRTC/DataChannel parsing, WebGPU-preferred tile upload, WebCodecs video payload handling, Canvas fallback harnesses, dirty-region state, and control-frame tests exist. A full live RDP desktop proof still depends on connector readiness. |
| Redirection controls | Implemented for denial | Clipboard, drive, printer, audio, smart-card, and file-copy stay disabled unless separately reviewed and explicitly enabled. |
| Recording and audit | Implemented for metadata | Lifecycle, policy, route, credential mode, frame statistics, and termination metadata are recorded without screen/clipboard/file/audio content by default. |
| Optional agent distribution | Implemented, experimental | Base agents stay free of IronRDP. RDP-capable artifacts are hidden unless RDP is enabled and still require helper readiness before advertising `remote_access.rdp`. |
| Live RDP connector | Not production-ready | Connector-linked probes cover TCP dial, HYBRID/HYBRID_EX negotiation, verified TLS, CredSSP finalization boundaries, KDC network client behavior, media-session binding, and finalized network-pump session handoff. `connector_ready` remains `false` until a live helper can complete auth, active-stage media, cleanup, and demo proof. |
| Teleport source import | Not approved | No current Teleport desktop/RDP code is imported. IronRDP is the reviewed protocol dependency path. |

## Optional Agent Packaging
The base ServiceRadar agent must remain the default artifact for most deployments. IronRDP and the `serviceradar-rdp-adapter` helper should be shipped only through an explicit remote-access/RDP artifact path, not silently embedded in every agent install.

Recommended release shape:

- `serviceradar-agent`: base agent artifact, no IronRDP helper, no `remote_access.rdp` advertisement.
- `serviceradar-rdp-adapter`: signed helper artifact built from the reviewed IronRDP crate set.
- optional `serviceradar-agent-rdp` or `serviceradar-agent-remote-access` bundle: base agent plus the matching helper for one-click deployments that want desktop access.

Forgejo release metadata should describe feature capabilities, compatibility, checksums, signatures, SBOM/license material, and helper requirements for each artifact. EdgeOps/web-ng should filter the available agent artifacts by deployment policy:

- deployments without the remote-access/RDP feature enabled see only base agent artifacts
- deployments with RDP enabled see the RDP helper/bundle artifacts and their compatibility status
- one-click deploys install the base agent plus helper only when the selected artifact declares `remote_access.rdp`
- installed agents still advertise `remote_access.rdp` only after local config enables RDP and the helper `--capabilities` probe reports a compatible protocol version and `connector_ready: true`; when readiness is false, the probe should include a stable `connector_ready_reason` for operator diagnostics

This keeps the default agent small, reduces the default attack surface, and makes the additional Rust/RDP dependency chain visible to operators who intentionally opt into it. Helper and agent versions should be pinned together or express an explicit compatibility range so an agent update cannot accidentally run an incompatible helper protocol.

## Validation
- Unit tests for desktop target/resource normalization rejecting client-selected upstream hosts, ports, credentials, redirection features, routes, quotas, and recording overrides.
- RBAC and approval tests proving access and redirection features are denied without explicit permission.
- Agent adapter tests proving TLS/NLA policy, credential non-persistence, frame quotas, credit-window backpressure, resize handling, timeout, and route-loss cleanup.
- Desktop media stream tests proving unrelated control-stream traffic is not blocked by frame bursts.
- Renderer tests proving keyboard, pointer, resize, focus, and close events map to typed frames without terminal assumptions.
- Recording tests proving metadata is stored and screen/clipboard/file/audio content is not retained by default.
- Demo proof with a private Windows RDP target or controlled RDP test server reachable only from an agent.
