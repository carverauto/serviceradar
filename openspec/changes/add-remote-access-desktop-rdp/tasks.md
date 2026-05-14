## 1. Design And Data Model
- [x] 1.1 Define registered desktop/RDP target resources, including route, TLS/NLA, credential mode, screen policy, redirection policy, approval, and recording fields.
- [x] 1.2 Define desktop session lifecycle, typed graphical frames, renderer control frames, cancellation semantics, and route binding shared by web-ng, core, agent-gateway, and agent.
- [x] 1.3 Define credential modes for domain-backed delegation, smart-card/certificate auth, memory-only per-session user credentials, and brokered fallback secrets.
- [x] 1.4 Record exact dependency choices for RDP protocol and browser rendering before implementation.

## 2. Policy, RBAC, And API
- [ ] 2.1 Add desktop target RBAC and approval checks that bind actor, target, route, policy snapshot, credential mode, and redirection policy to one session.
- [x] 2.1.1 Add the admin-only `devices.remote_access.rdp.open` RBAC catalog key for graphical desktop access.
- [ ] 2.2 Add APIs for listing authorized desktop targets, creating sessions, exchanging graphical/control frames, toggling approved redirection features, and closing sessions.
- [x] 2.2.1 Add web-ng WebRTC signaling endpoints for an existing RDP remote-access session: create offer, submit answer, add ICE candidates, and close viewer session.
- [x] 2.2.2 Gate desktop WebRTC signaling behind `remote_access_desktop_rdp_enabled` and reject non-RDP remote-access sessions.
- [x] 2.2.3 Include desktop WebRTC transport, signaling path, and ICE server metadata on RDP remote-access session responses.
- [x] 2.2.4 Add a supervised core-elx desktop WebRTC signaling owner behind the web-ng ERTS RPC facade.
- [ ] 2.3 Add policy enforcement for frame rate, bitrate, resolution, idle timeout, session TTL, redirection features, clipboard direction, and content-recording mode.
- [ ] 2.4 Add audit/recording metadata events for session lifecycle, credential mode, target TLS/NLA posture, frame statistics, redirection decisions, and termination reason.

## 3. Agent Route And RDP Adapter
- [ ] 3.1 Add typed desktop control frames to the agent-gateway control route and a dedicated desktop media stream for screen updates, without reusing terminal byte frames blindly.
- [ ] 3.1.1 Reuse the camera media relay architecture where practical: agent gRPC, gateway admission/session tracking, ERTS RPC forwarding, core-elx/web-ng ingress, chunk limits, heartbeat, and close semantics.
- [ ] 3.1.2 Add desktop-specific bidirectional credits/acks, quality downgrade, pause/resume, and browser backpressure handling before advertising `remote_access.rdp`.
- [ ] 3.1.3 Model desktop media flow control on a channel-window pattern: initial credit, max chunk size, window adjustment, EOF, close, and stale-frame coalescing/drop behavior.
- [x] 3.1.4 Add the Go-side SRDP binary desktop media frame envelope, ack validation, and credit-window helper that matches the browser parser contract.
- [x] 3.1.5 Add browser-side desktop media acknowledgements over the WebRTC control DataChannel with session/media binding and fresh credit.
- [x] 3.1.6 Add the Go-side browser control-message decoder for desktop media acknowledgements.
- [x] 3.1.7 Add production-oriented low-copy desktop media helpers for reusable headers, vectored writes, and no-copy frame views.
- [x] 3.1.8 Coalesce browser desktop media acknowledgements and return actual consumed byte credit instead of fixed per-frame credit.
- [ ] 3.2 Implement the agent RDP adapter for registered targets only, including TLS/NLA verification and credential handling.
- [ ] 3.3 Ensure credentials, generated keys, RDP files, and credential caches are memory-only and are dropped on session close, timeout, policy revocation, or route loss.
- [ ] 3.4 Add resize, keyboard, pointer, focus, backpressure, frame quota, bitrate quota, and route-loss behavior.

## 4. Operator And User Experience
- [ ] 4.1 Add web-ng target administration for desktop/RDP targets and redirection policy fields.
- [ ] 4.2 Add a browser graphical renderer for authorized RDP sessions with visible target identity, recording state, credential mode, redirection state, quota state, and approval status.
- [ ] 4.2.1 Implement the browser media golden path: WebRTC session/signaling, WebRTC media tracks for encoded video, WebRTC DataChannel for binary frame envelopes and backpressure, WebGPU dirty-region/tile renderer, WASM helper boundary, and explicit browser backpressure.
- [x] 4.2.1.1 Add the browser-side WebRTC signaling helper and binary desktop media frame parser/selector contract.
- [x] 4.2.1.2 Add the server-side web-ng WebRTC signaling facade/controller contract for `webrtc_desktop_media`.
- [ ] 4.2.2 Keep Apache Arrow IPC limited to structured desktop metadata, audit/stat snapshots, overlays, or frame manifests; do not use Arrow IPC as the default screen-pixel transport.
- [ ] 4.3 Add recording/audit views for desktop session lifecycle and metadata without screen frames, clipboard content, file content, or audio by default.
- [ ] 4.4 Add operator docs for registering RDP targets, configuring credential modes, target TLS/NLA trust, redirection controls, and session recording policy.

## 5. Validation And Demo
- [ ] 5.1 Add unit tests for resource normalization, override rejection, RBAC, approval, redirection gates, quota enforcement, and audit records.
- [x] 5.1.1 Add RBAC catalog tests for RDP open permission and Phoenix controller tests for desktop WebRTC signaling gates.
- [x] 5.1.2 Add core-elx tests for desktop WebRTC signaling lifecycle, missing sessions, unsupported protocols, answers, candidates, and expiry.
- [ ] 5.2 Add RDP adapter tests for TLS/NLA policy, credential non-persistence, rendering frames, resize, keyboard/pointer events, backpressure, cancellation, and cleanup.
- [ ] 5.3 Add route/session tests proving frames are accepted only on the selected route and terminate on revocation or route loss.
- [ ] 5.4 Add a demo proof path with a private Windows RDP target or controlled RDP test server reachable only from an agent.
- [ ] 5.5 Update the Teleport parity matrix after the RDP slice is implemented and validated.
- [ ] 5.6 Add desktop media performance tests for delayed links, browser backpressure, credit-window exhaustion, long-running frame bursts, and stale-frame coalescing/drop behavior.
- [x] 5.6.1 Add focused Go tests for desktop media frame encoding/decoding, validation, truncation rejection, ack validation, and credit-window exhaustion/adjustment.
- [x] 5.6.2 Add focused Go tests for browser desktop media acknowledgement control-message decoding.
- [x] 5.6.3 Add focused Go tests proving desktop media split-frame encoding reuses header buffers and avoids metadata/payload copies.
- [x] 5.6.4 Add Go desktop media hot-path benchmarks for contiguous encoding, split-frame/static-field encoding, copying decode, and no-copy decode.
- [ ] 5.7 Add browser renderer tests for WebRTC capability selection, DataChannel handling, WebGPU rendering, local Canvas harness behavior, dirty tile masks, queue limits, stale update coalescing, and Arrow metadata-only handling.
- [x] 5.7.1 Add browser WebRTC client tests for desktop media frame acknowledgement and credit emission over the control DataChannel.
- [x] 5.7.2 Add browser WebRTC client tests for coalesced desktop media acknowledgements and consumed-byte credit accounting.
