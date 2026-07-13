# Change: Add Proxmox QEMU graphical console

## Why

ServiceRadar can ask PVE for a QEMU `vncproxy` ticket and open its
`vncwebsocket`, but the current compatibility path forwards the resulting raw
RFB bytes through the terminal console bridge and xterm. That is neither a
graphical console nor a safe protocol boundary. It exposes an unbounded parser
surface to terminal infrastructure and bypasses the desktop media, input,
backpressure, renderer, and cleanup controls already built for graphical
access.

The secure agent-routed access program therefore keeps QEMU graphical
readiness false until a separately reviewed child parses RFB on the selected
edge agent, converts it into the existing desktop-media/control contracts, and
passes a deployed proof against one exact provider instance, parent PVE node,
and VMID.

## What Changes

- Add a default-off QEMU graphical capability that consumes the authoritative
  guest -> parent PVE -> provider instance -> endpoint -> selected route
  relationship and explicit session-scoped `console_access` grant supplied by
  the prerequisite Proxmox identity/terminal-console work.
- Bind PVE API and WebSocket egress to the registered HTTPS endpoint, verified
  TLS policy, exact QEMU node/VMID paths, selected agent/gateway route, and one
  authorized session. Browser input cannot select or override the PVE host,
  node, VMID, provider reference, credential, path, TLS policy, route, quotas,
  or recording policy.
- Replace the QEMU compatibility forwarding path with a ServiceRadar-owned,
  streaming RFB adapter inside the existing Proxmox edge-console boundary.
  The initial slice adds no third-party RFB or browser VNC implementation;
  existing HTTP/WebSocket and desktop-media dependencies remain subject to a
  recorded license, vulnerability, lockfile, Bazel, and SBOM review.
- Allow only the reviewed RFB version, security, pixel-format, and encoding
  subset needed by the controlled PVE fixture. Reject unsupported negotiation,
  messages, encodings, lengths, state transitions, clipboard traffic, and
  trailing data before they can reach a renderer or input sink.
- Add deterministic parser corpora, chunk-boundary/property tests, and bounded
  fuzzing for negotiation, server initialization, framebuffer updates,
  rectangle encodings, cursor/resize messages, fragmentation, truncation,
  oversized values, and malformed input.
- Translate decoded rectangles, tiles, cursor updates, and display metadata
  into the existing SRDP desktop-media envelope and translate approved
  keyboard, pointer, focus, quality, and close controls back into RFB client
  input. Raw RFB/VNC bytes MUST NOT enter terminal frames, xterm, core, gateway,
  recordings, or browser code.
- Reuse the existing WebRTC desktop-media path, credits, pause/resume, quality
  feedback, stale-frame handling, and graphical browser component. The browser
  receives protocol-neutral renderable pixels and typed control state, never a
  PVE URL, provider credential, ticket, cookie, CSRF value, or RFB stream.
- Enforce hard and policy limits for dimensions, decoded framebuffer bytes,
  rectangles, message/chunk size, frame rate, bitrate, byte credit, queue
  depth, input rate, concurrent sessions, negotiation time, idle time, and
  absolute duration. Exhaustion fails closed and cannot block unrelated agent
  control traffic.
- Make all failure paths terminal and idempotent: close the PVE WebSocket and
  desktop-media session, revoke the grant, discard tickets/credentials and
  parser/frame buffers, stop timers/work, emit only typed redacted errors, and
  record metadata-only lifecycle evidence.
- Gate capability and target readiness on the reviewed artifact/SBOM, parser
  self-test, compatible desktop-media and renderer builds, unambiguous current
  parent-PVE relationship, verified PVE trust, eligible live route, explicit
  console grant, actor authorization/approval, current proof, and secure-off
  deployment policy.
- Require a deployed browser -> web-ng -> core -> gateway -> selected agent ->
  PVE `vncwebsocket` proof for the controlled `farm01 / pve01 / qemu / 155`
  fixture after provider-identity prerequisites land. The evidence records the
  immutable provider-instance ID rather than relying on the display name
  `farm01`.

## Scope Boundaries

- This child does not implement or change PVE node shells, LXC `termproxy`,
  QEMU serial `termproxy`, xterm, SSH, or the generic Proxmox credential-rule
  and parent-target model. Those remain prerequisites owned by the Proxmox
  identity and terminal-console children.
- This child does not implement, modify, enable, test, or claim readiness for
  RDP. `add-remote-access-desktop-rdp` remains the sole owner of the RDP
  adapter, helper, Windows target, NLA/TLS policy, launch workflow, and live
  proof.
- This child does not add arbitrary VNC targets, direct browser-to-PVE access,
  a browser RFB/noVNC parser, a binary WebSocket media fallback, SPICE, power or
  configuration operations, clipboard, file transfer, audio, device
  redirection, or screen-content recording.
- This child consumes the generic authorization, attach-ticket, authenticated
  route, audit, metadata-recording, timeout, revocation, reaper, readiness, and
  desktop-media contracts. It changes those shared paths only where required to
  identify and safely carry the QEMU graphical protocol.

## Impact

- Affected specs: `proxmox-qemu-graphical-console` (new)
- Related changes: program `complete-secure-agent-routed-access`;
  prerequisite Proxmox provider-identity, terminal-console, and authoritative
  readiness children; `add-secure-agent-routed-remote-access`;
  `add-proxmox-plugin-credential-rules`; `harden-remote-access-security`;
  `add-remote-access-desktop-rdp`
- Affected code: `go/cmd/wasm-plugins/proxmox`, ServiceRadar plugin SDK/host
  graphical bridge surfaces, `go/pkg/agent/remoteaccess`, desktop-media sender,
  `proto/desktop_media.proto` only if compatibility requires an additive field,
  agent-gateway/core desktop-media admission and readiness integration,
  `elixir/serviceradar_core` Proxmox target/session integration,
  `elixir/web-ng` remote desktop renderer and device action, build/SBOM gates,
  tests, and remote-access documentation
- Operational impact: one new secure-off agent capability, bounded PVE
  graphical session resources, explicit proof evidence, and an opt-in canary
  rollout; no live environment or credential changes are authorized by this
  proposal
