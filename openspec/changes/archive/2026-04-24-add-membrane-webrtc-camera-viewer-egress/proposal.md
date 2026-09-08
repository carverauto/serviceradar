# Change: Add Membrane-backed WebRTC camera viewer egress

## Why
The camera relay work already gives us the right ingest architecture: agents open camera sources locally, push media through the gateway, and `serviceradar_core_elx` owns relay state and Membrane-managed ingest. The weak point is the browser egress path. Today live viewing still depends on the custom websocket H264 path and browser-specific decode behavior, which is workable for early rollout but not a good long-term browser contract.

We should move the preferred viewer path to WebRTC while keeping the existing edge uplink and relay model intact. That gives us a standards-based browser transport, better portability across browsers, and keeps the media-plane authority inside `serviceradar_core_elx` where Membrane already lives.

## What Changes
- Add a WebRTC viewer egress path in `serviceradar_core_elx` that reuses the existing Membrane relay ingest for each active camera session.
- Add viewer signaling/session negotiation between `web-ng` and `core-elx` so device pages and God-View can establish browser WebRTC sessions bound to existing relay sessions.
- Keep `agent -> gateway -> core-elx` ingest unchanged; this change only affects browser-facing egress.
- Prefer WebRTC for camera playback when the relay session advertises it, while keeping the current websocket viewer path as a rollout fallback until WebRTC is proven.
- Add configuration surfaces for ICE/STUN/TURN data needed by browser viewers, without introducing any direct browser-to-agent or browser-to-camera path.
- Add operational visibility for WebRTC negotiation failures and fallback selection so rollout issues are diagnosable.

## Impact
- Affected specs:
  - `camera-streaming` (modified)
  - `build-web-ui` (modified)
  - `edge-architecture` (modified)
- Affected code:
  - `elixir/serviceradar_core_elx/**`
  - `elixir/web-ng/**`
  - `elixir/serviceradar_core/**`
  - `elixir/serviceradar_agent_gateway/**` (only if viewer-facing metadata or relay state propagation needs minor updates)
- Dependencies:
  - Builds on `add-camera-stream-relay`
  - Builds on `harden-camera-relay-production-readiness`
  - Does not replace the existing camera media uplink or Wasm bridge architecture
