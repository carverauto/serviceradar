# Desktop Frame Contract

## Transport
The first RDP slice uses the existing `Monitoring.ConsoleFrame` control-stream payload as the compatibility wrapper for lifecycle, prototype, and low-rate control frames. The wrapper remains the route/session envelope:

- `session_id`: ServiceRadar remote-access session ID
- `frame_type`: one of the desktop frame type constants
- `data`: JSON-encoded `DesktopFrame` payload for typed desktop/control frames
- `reason`: close/error reason when applicable
- `timestamp`: sender timestamp

The open frame carries a JSON `DesktopOpenPayload` in `data`. That payload contains the trusted target policy snapshot compiled by core, including route, upstream, TLS/NLA, credential mode, screen policy, redirection policy, approval, and recording policy.

This avoids changing protobuf wire compatibility before the RDP adapter proves the shape. Production screen updates must move to a dedicated desktop media stream with explicit backpressure before the agent advertises `remote_access.rdp` as an operational capability. A later high-volume implementation may add a dedicated protobuf `DesktopFrame` or `DesktopMediaFrame` payload, but it must preserve the same logical fields and policy boundaries.

## Control Stream And Media Stream Split
Control stream frames are for lifecycle and low-rate control:

- `open`
- `ready`
- `close`
- `error`
- keyboard, pointer, resize, focus, quality, and redirection-control events

Screen update payloads are media, not terminal bytes. They need a dedicated stream with sequence numbers, byte/frame credits, acknowledgements, pause/resume, and quality downgrade signals. This keeps large desktop frame bursts from blocking unrelated control traffic and gives the browser path a way to apply backpressure before gateway or BEAM process buffers grow.

The dedicated stream should follow the same deployment shape as the existing camera media relay path: agent gRPC to agent-gateway, gateway session tracking/admission, ERTS RPC forwarding into core-elx/web-ng, and browser delivery from the control plane. The schema should be desktop-specific, or a carefully generalized media relay schema, because camera source/profile fields do not map cleanly to RDP sessions.

## Browser Media Frame Envelope
Production browser screen payloads should use WebRTC, not a parallel binary WebSocket media transport. DataChannel payloads use a compact binary envelope, not JSON and not Arrow IPC for the pixel stream. Encoded video payloads may use a WebRTC media track when the adapter can produce a browser-decodable stream.

Minimum browser media envelope fields:

- `magic` and `version`
- `session_id` or compact session binding ID
- `media_session_id`
- `sequence`
- `payload_family`: `video`, `dirty_rect`, `tile`, `cursor`, or `metadata`
- `encoding`: codec or pixel/tile encoding
- `width` and `height`
- dirty rectangle or tile metadata length
- flags for keyframe, full frame, cursor update, end-of-stream, and discontinuity
- presentation timestamp
- payload length
- payload bytes

Renderer expectations:

- Encoded video payloads should prefer a WebRTC media track; WebCodecs remains useful for harnesses or non-track decoded frame paths.
- Dirty rectangle or tile payloads should ride WebRTC DataChannel and prefer WebGPU texture updates. Canvas2D is an early local harness path, not the production media strategy.
- Browser workers or WASM helpers may parse envelopes, maintain dirty-region state, compute tile masks, and prepare GPU upload descriptors.
- Roaring bitmaps may represent dirty tile masks when a fixed tile grid is used.
- Apache Arrow IPC may carry structured metadata, frame statistics, audit overlays, or optional frame manifests. It must not be the default screen-pixel transport.
- The browser must drop or coalesce stale non-keyframe updates when render queues exceed policy, then send backpressure/quality acknowledgements upstream.

## Lifecycle
1. web-ng requests a session for a registered RDP target.
2. core resolves RBAC, approval, route, target policy, credential mode, and recording policy.
3. gateway sends `open` with `DesktopOpenPayload` to the selected agent.
4. agent validates the target policy snapshot and credential grant before dialing.
5. agent replies `ready` only after the adapter has accepted the policy and is prepared to negotiate RDP.
6. browser and agent exchange low-rate typed desktop control frames over the selected route.
7. agent sends screen update chunks over the dedicated desktop media stream after receiving media stream readiness and credit.
8. either side may send `desktop.disconnect` or `close`.
9. route loss, revocation, timeout, media backpressure exhaustion, or policy failure closes the RDP connection, erases credential material, and emits a metadata recording event.

## Frame Types
- `desktop.update`: target-to-browser graphical update. Prototype/control-stream use only; production screen updates move through the dedicated desktop media stream.
- `desktop.input`: browser-to-target keyboard, pointer, or focus event.
- `desktop.resize`: browser-to-agent resize request. Enforces max dimensions.
- `desktop.clipboard`: optional clipboard payload. Disabled unless policy explicitly allows the direction and content type.
- `desktop.quality`: browser-to-agent quality request. Enforces frame-rate, bitrate, and resolution policy.
- `desktop.disconnect`: typed disconnect reason.

## Policy Binding
All desktop frames are valid only inside the route-bound session created by the `open` frame. Clients cannot change target host, port, route, credential mode, redirection policy, screen quotas, approval, or recording policy after session creation.

Redirection channels are disabled by default. Any clipboard, drive, printer, audio, smart-card, or file-copy behavior requires explicit target policy and user permission before a frame is accepted.
