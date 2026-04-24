## Context
The platform already has the correct upstream architecture for camera media:
- the agent owns camera reachability
- the gateway terminates edge gRPC and forwards media into platform-local ingress
- `serviceradar_core_elx` owns Membrane ingest, relay state, and viewer fan-out

What remains non-ideal is the browser delivery contract. The current websocket H264 path is custom, depends on browser-specific decode behavior, and forces us to maintain compatibility logic in the UI. WebRTC is a better browser egress protocol, but we should add it without disturbing the edge-side media plane that is already working.

## Goals
- Make WebRTC the preferred camera viewer transport for device pages and God-View.
- Keep one upstream relay ingest per camera/profile and reuse it for all viewers.
- Keep browser signaling and viewer authorization tied to the existing relay session model.
- Keep websocket viewer playback available as a fallback during rollout.
- Keep agent/gateway/core ingest unchanged.

## Non-Goals
- Replacing the existing agent-originated camera uplink with WebRTC.
- Making browsers connect directly to edge agents or cameras.
- Replacing Membrane with raw `ex_webrtc` session plumbing outside the media pipeline.
- Introducing a brand-new TURN service implementation in this change.

## Architecture
### Media-plane boundary
`serviceradar_core_elx` remains the media-plane authority. The Membrane relay pipeline continues to accept one upstream ingest per active relay session. The new work adds a browser egress branch that packages the relay output for WebRTC viewers.

### WebRTC stack shape
- `web-ng` owns browser-facing authorization and signaling entrypoints.
- `core-elx` owns the actual WebRTC media egress state bound to a relay session.
- The browser negotiates a viewer session against the existing relay session identifier.
- WebRTC egress is treated as another playback transport advertised by the relay session, alongside the current websocket fallback.

This means the browser contract changes, but the edge contract does not.

### Signaling model
The viewer should not create a free-floating PeerConnection unrelated to relay state. Instead:
1. The browser opens or attaches to a relay session the same way it does today.
2. The UI requests a WebRTC viewer negotiation for that relay session.
3. `core-elx` returns the relay-scoped offer/answer or equivalent signaling data plus ICE server configuration.
4. The browser sends answer/candidate updates back through authenticated signaling endpoints.
5. Viewer count and relay lifecycle continue to flow through the same relay session model.

### Fallback model
WebRTC becomes the preferred playback transport, but the current websocket viewer path remains available as a fallback while rollout is in progress. Fallback is driven by advertised transport metadata and browser capability checks, not by a separate relay model.

## Key Decisions
### Use WebRTC only on browser egress
The current edge-side transport is already aligned with our deployment reality and should remain stable. WebRTC only solves the browser delivery problem; it does not improve the agent uplink path.

### Keep Membrane at the center
The new work should use Membrane-backed WebRTC egress rather than bypassing the existing relay pipeline. This preserves the single-ingest/multi-viewer model and avoids splitting media responsibilities across two unrelated stacks.

### Keep fallback during rollout
The websocket path should remain as a fallback until WebRTC is stable across the browsers and network conditions we care about. Removing fallback too early would turn a delivery improvement into an availability regression.

## Risks
### ICE/TURN complexity
Browser WebRTC adds ICE negotiation concerns that do not exist in the current websocket viewer path. The change therefore needs explicit ICE/TURN configuration surfaces and failure observability, even if it initially relies on configured external infrastructure.

### Relay-state drift
If WebRTC viewer sessions are allowed to drift away from the persisted relay session model, viewer count, idle-close, and error reporting will become inconsistent. All signaling and viewer lifecycle actions must remain relay-session-scoped.

### Dual transport rollout
Running both WebRTC and websocket egress during rollout adds surface area. The implementation must keep transport selection explicit and observable so operators can tell which path was used and why fallback occurred.
