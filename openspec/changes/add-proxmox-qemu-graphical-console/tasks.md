## 1. Prerequisites and secure-off boundary

- [ ] 1.1 Rebase this child after canonical remote-access reconciliation,
  authoritative readiness, provider-instance identity, and Proxmox
  terminal-console/session prerequisites land; resolve conflicts without
  taking ownership of their requirements.
- [ ] 1.2 Add QEMU graphical mode as a distinct default-off action/capability;
  keep it unavailable when any prerequisite relationship, route, trust,
  credential, adapter, renderer, policy, or proof dependency is absent.
- [ ] 1.3 Remove or hard-disable every compatibility path that can forward QEMU
  `vncwebsocket` bytes as terminal `ConsoleFrame` data or render them in xterm.
- [ ] 1.4 Add ownership regression checks proving PVE/LXC/QEMU serial terminals
  remain on their terminal child and RDP adapter/helper/target/proof code remains
  owned only by `add-remote-access-desktop-rdp`.

## 2. Dependency, license, and artifact review

- [ ] 2.1 Add the ServiceRadar-owned streaming RFB parser without importing a
  third-party RFB/noVNC/browser decoder or copying/translating Teleport, noVNC,
  QEMU, or another VNC implementation.
- [ ] 2.2 Record exact Go/Bazel/Wasm/SDK direct and transitive dependencies,
  versions, features, source origins, licenses, lockfile/repository changes,
  platform support, and vulnerability/advisory results for the graphical
  artifact and host bridge.
- [ ] 2.3 Generate and verify artifact SBOM/license output, reject incompatible
  or unreviewed dependency paths, and bind the accepted SBOM to the signed Wasm
  and agent/plugin build digests used by readiness evidence.
- [ ] 2.4 Add CI gates that fail on an unrecorded RFB/compression/browser
  dependency, disallowed license, failed vulnerability policy, stale SBOM, or
  artifact/SBOM digest mismatch.

## 3. Authoritative PVE session bootstrap

- [ ] 3.1 Consume exactly one prerequisite-resolved canonical QEMU guest,
  immutable provider instance, parent PVE host, node, VMID, registered HTTPS
  endpoint/trust policy, selected agent/gateway route, and console custody
  policy; reject all browser overrides and ambiguous/stale relationships.
- [ ] 3.2 Bind the session-scoped console grant to actor, session, guest, parent
  PVE, provider instance, node, VMID, endpoint, route, action, and expiry before
  credential resolution.
- [ ] 3.3 Implement only the exact escaped QEMU `vncproxy` and `vncwebsocket`
  paths on the registered PVE origin with verified CA/server identity, no
  redirects, no cleartext transport, and no insecure readiness mode.
- [ ] 3.4 Bound and validate proxy responses and WebSocket negotiation; keep PVE
  credentials, Authorization headers, tickets, cookies, CSRF values, response
  bodies, and full upstream URLs out of browser, core/gateway frames, durable
  state, logs, traces, audit, recordings, and support output.

## 4. Bounded RFB parser and fuzzing

- [ ] 4.1 Implement an incremental checked RFB 3.8 state machine for the exact
  reviewed PVE security negotiation, `ServerInit`, framebuffer updates, Raw,
  CopyRect, Hextile, DesktopSize, and the required cursor pseudo-encoding.
- [ ] 4.2 Reject unreviewed versions, security fallbacks, pixel formats,
  encodings, messages, clipboard/client-cut-text, invalid state transitions,
  lengths, dimensions, rectangles, cursor masks, arithmetic, truncation,
  overlap, and trailing bytes before allocation, output, or input effects.
- [ ] 4.3 Add a deterministic secret-free corpus covering PVE handshake and
  framebuffer behavior, arbitrary WebSocket/RFB chunk boundaries, partial
  reads, reconnect/close boundaries, and every supported encoding.
- [ ] 4.4 Add bounded native Go fuzz/property tests for negotiation, message
  parsing, rectangle decoders, fragmentation, truncation, oversized values,
  invalid encodings, and state sequences; assert no panic, uncontrolled
  allocation/CPU, raw-byte leak, or output outside typed updates/errors.
- [ ] 4.5 Add parser self-tests and malformed-input/timeout tests to capability
  probing so a failed parser or incompatible negotiation profile withdraws the
  local QEMU graphical capability.

## 5. Existing desktop media, control, and renderer integration

- [ ] 5.1 Extend the plugin/agent graphical bridge with protocol-neutral typed
  desktop media/control only; prohibit PVE secrets, upstream URLs, and raw RFB
  from crossing the bridge.
- [ ] 5.2 Convert validated RFB pixels to canonical `rgba8888` SRDP dirty
  rectangles/tiles and cursor updates with session/media binding, sequence,
  dimensions, flags, and bounded metadata; split large output into existing
  desktop-media chunk limits.
- [ ] 5.3 Map approved keyboard, pointer, focus, quality, pause/resume, close,
  and capability-gated resize controls to bounded RFB client messages; reject
  clipboard, file, audio, redirection, and unsupported key/button input.
- [ ] 5.4 Reuse the existing desktop-media gRPC, gateway admission/tracker, ERTS
  ingress, WebRTC DataChannel, SRDP envelope, byte credits, and close semantics;
  do not add screen media to the generic agent control stream or a browser
  binary WebSocket fallback.
- [ ] 5.5 Reuse the web-ng `RemoteAccessDesktopSession` WebGPU-preferred/Canvas
  renderer for QEMU protocol-neutral pixels, target/parent identity, policy and
  connection status; add no browser RFB/noVNC parser and no xterm fallback.

## 6. Resource, lifecycle, and readiness enforcement

- [ ] 6.1 Enforce the design's compiled hard caps and the lower effective
  screen/session policy for dimensions, framebuffer bytes, rectangles, chunk
  size, queued bytes/frames, frame rate, bitrate, input rate/token size,
  concurrent sessions, negotiation, idle, and absolute duration.
- [ ] 6.2 Integrate existing desktop byte credits, pause/resume, quality
  feedback, stale-update coalescing/drop, and control-stream isolation; close a
  peer that exceeds bounds or cannot make bounded progress.
- [ ] 6.3 Implement one idempotent terminal cleanup for close, auth/parser/media
  error, quota exhaustion, route loss, revocation, timeout, browser loss,
  adapter crash, agent shutdown, and orphan reaping; close PVE/media resources,
  release capacity, revoke grants/tickets, and clear owned secret/frame/parser
  buffers.
- [ ] 6.4 Advertise
  `remote_access.proxmox.qemu_graphical.rfb_v1` only from applied secure-off
  policy plus compatible signed artifact/SBOM, bridge/media contract, parser
  self-test, and capacity health.
- [ ] 6.5 Require current target proof and atomically re-evaluate identity,
  placement, endpoint/TLS, route, console custody policy, artifact/parser/media/
  renderer build, quotas, authorization/approval, recording policy, and proof
  freshness at action display, create, and attach.
- [ ] 6.6 Map all PVE, WebSocket, RFB, quota, route, credential, media, and
  renderer failures to stable typed public codes while retaining only redacted
  access-controlled diagnostics and metadata-only audit/proof records.

## 7. Verification, live proof, and rollback

- [ ] 7.1 Add unit and integration tests for path/origin/TLS/route/target
  override denial, proxy response bounds, negotiation, pixel conversion,
  cursor/input mapping, media binding, credits, queue exhaustion, timeouts,
  wrong-route frames, and idempotent cleanup.
- [ ] 7.2 Add secret/raw-protocol non-disclosure tests across plugin bridge,
  terminal frames, xterm, browser payloads/state, core/gateway state, logs,
  traces, audit, recordings, errors, crash reports, and support bundles.
- [ ] 7.3 Add browser tests for full/incremental/cursor rendering, keyboard and
  pointer control, stale-frame handling, pause/resume, route loss, sanitized
  errors, no terminal fallback, and metadata-only recording indicators.
- [ ] 7.4 Resolve and record the immutable provider instance and canonical
  guest/parent identities for display tuple `farm01 / pve01 / qemu / 155`, then
  pass the deployed browser-to-PVE proof for verified TLS/auth, RFB handshake,
  first/full and incremental frames, cursor, input, backpressure, route loss,
  timeout/reaper cleanup, and non-disclosure.
- [ ] 7.5 Store the proof's exact deployment, target/identity/placement, route,
  trust/custody/policy, agent/artifact/SBOM/parser/bridge/media/renderer builds,
  tested capabilities, result, freshness deadline, evidence digest, and audit
  reference without secrets.
- [ ] 7.6 Enable only the proved canary target, verify secure-off behavior for
  every other QEMU guest, and document rollback that disables the capability,
  rejects new sessions, closes active sessions, revokes grants/tickets, frees
  resources, and leaves terminal consoles and RDP unchanged.
