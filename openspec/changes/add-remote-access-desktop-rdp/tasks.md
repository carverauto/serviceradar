## 1. Design And Data Model
- [x] 1.1 Define registered desktop/RDP target resources, including route, TLS/NLA, credential mode, screen policy, redirection policy, approval, and recording fields.
- [ ] 1.2 Define desktop session lifecycle, typed graphical frames, renderer control frames, cancellation semantics, and route binding shared by web-ng, core, agent-gateway, and agent.
- [x] 1.3 Define credential modes for domain-backed delegation, smart-card/certificate auth, memory-only per-session user credentials, and brokered fallback secrets.
- [x] 1.4 Record exact dependency choices for RDP protocol and browser rendering before implementation.

## 2. Policy, RBAC, And API
- [ ] 2.1 Add desktop target RBAC and approval checks that bind actor, target, route, policy snapshot, credential mode, and redirection policy to one session.
- [ ] 2.2 Add APIs for listing authorized desktop targets, creating sessions, exchanging graphical/control frames, toggling approved redirection features, and closing sessions.
- [ ] 2.3 Add policy enforcement for frame rate, bitrate, resolution, idle timeout, session TTL, redirection features, clipboard direction, and content-recording mode.
- [ ] 2.4 Add audit/recording metadata events for session lifecycle, credential mode, target TLS/NLA posture, frame statistics, redirection decisions, and termination reason.

## 3. Agent Route And RDP Adapter
- [ ] 3.1 Add typed desktop frames to the agent-gateway route without reusing terminal byte frames blindly.
- [ ] 3.2 Implement the agent RDP adapter for registered targets only, including TLS/NLA verification and credential handling.
- [ ] 3.3 Ensure credentials, generated keys, RDP files, and credential caches are memory-only and are dropped on session close, timeout, policy revocation, or route loss.
- [ ] 3.4 Add resize, keyboard, pointer, focus, backpressure, frame quota, bitrate quota, and route-loss behavior.

## 4. Operator And User Experience
- [ ] 4.1 Add web-ng target administration for desktop/RDP targets and redirection policy fields.
- [ ] 4.2 Add a browser graphical renderer for authorized RDP sessions with visible target identity, recording state, credential mode, redirection state, quota state, and approval status.
- [ ] 4.3 Add recording/audit views for desktop session lifecycle and metadata without screen frames, clipboard content, file content, or audio by default.
- [ ] 4.4 Add operator docs for registering RDP targets, configuring credential modes, target TLS/NLA trust, redirection controls, and session recording policy.

## 5. Validation And Demo
- [ ] 5.1 Add unit tests for resource normalization, override rejection, RBAC, approval, redirection gates, quota enforcement, and audit records.
- [ ] 5.2 Add RDP adapter tests for TLS/NLA policy, credential non-persistence, rendering frames, resize, keyboard/pointer events, backpressure, cancellation, and cleanup.
- [ ] 5.3 Add route/session tests proving frames are accepted only on the selected route and terminate on revocation or route loss.
- [ ] 5.4 Add a demo proof path with a private Windows RDP target or controlled RDP test server reachable only from an agent.
- [ ] 5.5 Update the Teleport parity matrix after the RDP slice is implemented and validated.
