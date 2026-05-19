# Desktop Transport Analysis

## Question
Can RDP screen traffic safely use the existing agent control stream, or does it need a dedicated stream?

## Short Answer
Use the existing control stream for lifecycle and low-rate control only. Do not use it as the production path for high-volume RDP screen updates.

The initial `ConsoleFrame` compatibility wrapper is acceptable for proving policy shape, frame vocabulary, and simple harnesses. It should not be the architecture for a usable desktop session.

## Why The Generic Control Stream Is The Wrong Production Path
The control stream currently carries agent registration, commands, config, console frames, file-transfer control/data frames, heartbeats, and remote-access session lifecycle messages. RDP screen traffic has a very different profile:

- bursty screen updates
- large payloads
- browser-dependent render backpressure
- per-session bitrate and frame-rate adaptation
- sensitive screen content with different retention rules than metadata
- lower tolerance for head-of-line blocking

If screen updates share the generic control stream, one busy desktop session can delay unrelated agent operations. On the gateway/web side, large frame bursts can also grow process mailboxes and PubSub fanout pressure before the browser has proven it can render the data.

## Recommended Split
Control stream:

- open/ready/close/error
- policy snapshot
- credential grant delivery
- approval/revocation/forced termination
- keyboard, pointer, resize, focus, quality-control, and redirection-control messages
- metadata recording events

Desktop media stream:

- screen update chunks
- cursor updates
- frame timing and byte statistics
- backpressure acknowledgements
- pause/resume/quality downgrade commands

## Reusing The Camera Media Pipeline
The desktop media stream should follow the existing camera relay pipeline where it fits:

```text
agent gRPC stream
  -> agent-gateway media service and session tracker
  -> ERTS RPC forwarder
  -> core-elx/web-ng media ingress
  -> browser renderer
```

This is the right starting point because the camera path already separates media from monitoring/control RPCs, tracks relay sessions at the gateway, enforces chunk sizes, uses heartbeat/lease semantics, and forwards accepted sessions into core-elx through ERTS RPC.

Do not reuse camera domain names directly for desktop. RDP needs desktop-specific session IDs, stream IDs, frame metadata, quality controls, and recording policy. The implementation should either create `desktop_media.proto` or extract a generic media relay shape that both camera and desktop can use without forcing camera concepts such as `camera_source_id` or `stream_profile_id` onto desktop sessions.

Differences from camera media:

- RDP needs browser-to-agent feedback for credit windows, quality downgrades, pause/resume, and close.
- RDP needs lower latency than camera viewing because keyboard and pointer interactions depend on render freshness.
- RDP must keep screen payload retention separate from metadata recording by default.
- RDP must be able to slow or stop the Rust helper when the browser path is backpressured.

The first implementation can model this as bidirectional gRPC. If the existing client/server stack makes bidirectional streaming awkward in one layer, use an upload stream plus a control/ack RPC, but the behavior must still be credit based.

## Browser Delivery Golden Path
Desktop screen payloads should reach the browser through a media-oriented binary path, not through JSON control frames or Arrow IPC record batches.

Recommended browser path:

```text
web-ng desktop media endpoint
  -> WebRTC signaling and media session
  -> browser worker / WASM helper
  -> WebRTC video track or WebGPU renderer
```

Reuse the camera relay WebRTC transport ideas:

- web-ng/core-elx signaling endpoints and relay-scoped viewer sessions
- WebRTC media tracks for encoded video payloads
- WebRTC DataChannel for dirty rectangles, tiles, cursor updates, quality/backpressure, and low-latency input/control frames
- binary media frames with small headers and large payload bytes when using DataChannel payloads
- capability negotiation for RTCPeerConnection, DataChannel, WebGPU, WebCodecs, and Canvas2D harnesses
- decoder/render queue limits
- frame dropping or dirty-region coalescing when the browser falls behind
- visible status for target identity, recording, redirection, and stream quality

Do not implement a browser binary WebSocket media fallback for desktop screen payloads. WebSockets are acceptable for signaling/status/control paths that already exist in web-ng, but a second browser media transport would duplicate backpressure, recording, policy, and test obligations.

Reuse the topology/God View data-plane ideas only where the data shape matches:

- WebGPU texture updates make sense for dirty rectangles, tiles, cursor composition, watermarks, and overlays.
- WASM makes sense for parsing frame envelopes, maintaining region/tile state, computing dirty masks, and producing GPU upload descriptors.
- Roaring bitmaps may be useful for fixed-grid dirty tile masks or changed-region sets.
- Apache Arrow IPC is useful for structured metadata, audit/stat snapshots, overlay datasets, or optional frame manifests. It should not wrap bulk screen pixels because the framebuffer is dense image/video data, not columnar analytical data.

The renderer should support two payload families:

- `video`: browser-decodable encoded frames, preferably as a WebRTC media track.
- `regions`: dirty rectangles or tile updates over WebRTC DataChannel, preferably uploaded to WebGPU textures.

## Devolutions Gateway Findings
The local Devolutions Gateway checkout is useful architecture reference for this RDP slice. Treat it as design input only until a separate exact-file license and dependency review approves any import.

Useful patterns:

- The JET model uses short-lived, signed association tokens to bind a client, relay, destination, protocol, recording policy, and session. ServiceRadar should use the same shape conceptually: session-bound grants, short TTLs, public-key verification at relays, and no unsigned tokens outside local development.
- JET explicitly treats destination username and password claims as sensitive. ServiceRadar should go further for browser-launched desktop sessions: do not put RDP passwords in browser-visible tokens. Keep per-session user credentials or brokered fallback secrets in server/agent memory only.
- The agent tunnel separates a low-rate control stream from per-session bidirectional streams. That matches the ServiceRadar split between existing agent control traffic and a dedicated desktop media stream.
- JMUX uses per-channel windows, window adjustment, maximum packet sizes, EOF, and close messages. The desktop media stream should use the same credit-window idea even if the wire format is gRPC rather than JMUX.
- JMUX performance notes show that poor flow-control sizing collapses under latency. RDP validation should include delayed-link tests, credit-window exhaustion, and long-running frame bursts.
- Traffic audit is emitted once at stream cleanup with target, outcome, duration, and byte counts. ServiceRadar should emit one terminal desktop transport audit event per stream, plus higher-level session lifecycle events.
- The video-streamer crate includes adaptive frame skipping when encoding falls behind real time. Desktop rendering should prefer coalescing or dropping stale dirty regions over buffering old frames that the browser can no longer render usefully.

Potential future consideration:

- RDP preconnection PDU token injection is relevant if ServiceRadar later supports native RDP clients. It is not necessary for the first browser-rendered helper path.

## Dedicated Stream Requirements
The desktop media stream should be bidirectional, session-scoped, and route-bound.

Minimum frame fields:

- `session_id`
- `media_session_id`
- `sequence`
- `kind`
- `width`
- `height`
- `encoding`
- `dirty_regions`
- `payload`
- `is_keyframe`
- `timestamp_unix_nano`

Minimum ack fields:

- `session_id`
- `media_session_id`
- `last_accepted_sequence`
- `credit_bytes`
- `credit_frames`
- `quality_level`
- `paused`
- `close_reason`

The gateway/browser path must be able to stop or slow the agent when buffers fill. The agent must then stop reading from the Rust RDP helper, request lower quality, or close the session.

## Local Agent Helper Boundary
The Rust IronRDP helper should be per-session and local to the agent host:

```text
serviceradar-agent
  -> starts serviceradar-rdp-adapter for one approved session
  -> sends memory-only policy and credential grant over local IPC
  -> receives screen chunks over local IPC
  -> relays screen chunks over the dedicated desktop media stream
  -> kills helper on close, timeout, revocation, route loss, or helper fault
```

Local IPC should use length-prefixed binary frames for screen payloads. JSON is acceptable for low-rate policy/control envelopes but should not wrap large screen payloads.

## Packaging Impact
The agent package should include the helper binary:

```text
serviceradar-agent
serviceradar-rdp-adapter
```

Automatic deployment from core/web-ng should still deploy one selected agent artifact version. The agent advertises `remote_access.rdp` only when local policy enables RDP and the installed helper `--capabilities` probe reports the expected helper protocol version and `connector_ready: true`.

## Open Questions Before Implementation
- Whether to create a new `desktop_media.proto` service or extend the existing camera media service with a generic media session shape.
- Whether the first WebRTC implementation should carry encoded video as a media track, region/tile frames over DataChannel, or both.
- Whether the first production renderer prioritizes encoded video frames or dirty rectangle/tile updates.
- How much frame data, if any, may be retained for recording when screen recording is enabled.
- Which controlled RDP target to use in CI: xrdp, a fixture server, or a Windows test host.
