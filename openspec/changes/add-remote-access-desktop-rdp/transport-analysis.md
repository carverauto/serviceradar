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

Automatic deployment from core/web-ng should still deploy one agent artifact version. The agent advertises `remote_access.rdp` only when the helper exists, matches the expected protocol version, and local policy enforcement is enabled.

## Open Questions Before Implementation
- Whether to create a new `desktop_media.proto` service or extend the existing camera media service with a generic media session shape.
- Whether the browser receives frame chunks through a Phoenix channel, a dedicated websocket, or another media endpoint.
- Whether the first renderer should consume bitmap dirty rectangles, encoded images, or a video-like stream.
- How much frame data, if any, may be retained for recording when screen recording is enabled.
- Which controlled RDP target to use in CI: xrdp, a fixture server, or a Windows test host.
