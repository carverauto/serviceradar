# Desktop Frame Contract

## Transport
The first RDP slice uses the existing `Monitoring.ConsoleFrame` control-stream payload as the compatibility wrapper. The wrapper remains the route/session envelope:

- `session_id`: ServiceRadar remote-access session ID
- `frame_type`: one of the desktop frame type constants
- `data`: JSON-encoded `DesktopFrame` payload for typed desktop/control frames
- `reason`: close/error reason when applicable
- `timestamp`: sender timestamp

The open frame carries a JSON `DesktopOpenPayload` in `data`. That payload contains the trusted target policy snapshot compiled by core, including route, upstream, TLS/NLA, credential mode, screen policy, redirection policy, approval, and recording policy.

This avoids changing protobuf wire compatibility before the RDP adapter proves the shape. A later high-volume implementation may add a dedicated protobuf `DesktopFrame` payload, but it must preserve the same logical fields and policy boundaries.

## Lifecycle
1. web-ng requests a session for a registered RDP target.
2. core resolves RBAC, approval, route, target policy, credential mode, and recording policy.
3. gateway sends `open` with `DesktopOpenPayload` to the selected agent.
4. agent validates the target policy snapshot and credential grant before dialing.
5. agent replies `ready` only after the adapter has accepted the policy and is prepared to negotiate RDP.
6. browser and agent exchange typed desktop frames over the selected route.
7. either side may send `desktop.disconnect` or `close`.
8. route loss, revocation, timeout, or policy failure closes the RDP connection, erases credential material, and emits a metadata recording event.

## Frame Types
- `desktop.update`: target-to-browser graphical update. Enforces max dimensions and max frame payload size.
- `desktop.input`: browser-to-target keyboard, pointer, or focus event.
- `desktop.resize`: browser-to-agent resize request. Enforces max dimensions.
- `desktop.clipboard`: optional clipboard payload. Disabled unless policy explicitly allows the direction and content type.
- `desktop.quality`: browser-to-agent quality request. Enforces frame-rate, bitrate, and resolution policy.
- `desktop.disconnect`: typed disconnect reason.

## Policy Binding
All desktop frames are valid only inside the route-bound session created by the `open` frame. Clients cannot change target host, port, route, credential mode, redirection policy, screen quotas, approval, or recording policy after session creation.

Redirection channels are disabled by default. Any clipboard, drive, printer, audio, smart-card, or file-copy behavior requires explicit target policy and user permission before a frame is accepted.
