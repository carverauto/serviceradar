# Design: ERTS-native camera relay ingress and Wasm streaming plugin mode

## Context
The current camera relay MVP established a dedicated edge-facing media service and a Membrane relay in `serviceradar_core_elx`, but it took the simplest forwarding path inside the platform: `agent -> agent-gateway` gRPC and `agent-gateway -> core-elx` gRPC. That is operationally workable, but it is not aligned with the rest of the platform, where gateways terminate edge gRPC and then hand off internally over ERTS.

The current Wasm runtime has a similar mismatch. It was designed for bounded plugin invocations that call host functions, emit a `plugin_result`, and return. Camera discovery fits that model. Live video does not. If a plugin is expected to originate or normalize a vendor media feed, the runtime needs a long-lived execution mode, cancellation, backpressure-aware host functions, and a shared native uploader behind the host bridge.

## Goals / Non-Goals
- Goals:
  - Restore the normal ServiceRadar transport boundary: edge gRPC terminates at the gateway, platform-internal media ingress uses ERTS.
  - Avoid per-chunk distributed RPC calls for camera media forwarding.
  - Support plugin-owned live camera media without abusing `plugin_result`.
  - Keep one relay lease/drain/backpressure implementation for both native and plugin-provided camera sources.
  - Preserve the existing edge-facing camera media proto so agents do not need a second external transport.
- Non-Goals:
  - Replacing the existing edge-facing camera media proto.
  - Moving edge agents into the ERTS cluster.
  - Carrying live media through `submit_result` or `GatewayServiceStatus`.
  - Turning generic Wasm plugins into arbitrary long-lived daemons without explicit streaming-mode assignment and controls.

## Decisions

### Decision 1: `agent-gateway -> core-elx` camera media forwarding becomes ERTS-native

**Choice**: `serviceradar-agent-gateway` SHALL terminate edge gRPC and forward camera media to `serviceradar_core_elx` over ERTS-native processes/messages instead of opening a second gRPC channel.

**Rationale**:
- Matches the existing gateway design used for status/results ingestion.
- Removes an avoidable internal transport layer.
- Keeps media ingress inside the platform’s clustered supervision model.

### Decision 2: `core-elx` owns per-session ingress processes

**Choice**: `serviceradar_core_elx` SHALL allocate a per-relay-session ingress process that owns relay admission, chunk receive, and Membrane handoff for that session.

**Rationale**:
- Avoids `:rpc.call` per chunk.
- Gives the gateway a stable ERTS target for the session lifetime.
- Localizes drain/closing/backpressure behavior to one process per relay session.

### Decision 3: Edge gRPC remains the only edge-facing media transport

**Choice**: The dedicated camera media gRPC service remains the only external transport between edge agents and gateways.

**Rationale**:
- Preserves outbound-only edge connectivity.
- Reuses the current mTLS and lease model.
- Keeps the gateway as the protocol termination boundary for edge traffic.

### Decision 4: Wasm live media uses a separate streaming plugin mode

**Choice**: The agent SHALL add a distinct streaming plugin mode for long-lived media sessions, separate from the current bounded execution mode that produces `plugin_result`.

**Rationale**:
- Live media requires long-lived execution, cancellation, and flow control semantics that the current one-shot runtime does not provide.
- This keeps scheduled checks and media streaming isolated in configuration, accounting, and failure handling.

### Decision 5: Wasm plugins use a host media bridge backed by a shared native uploader

**Choice**: Streaming plugins SHALL call dedicated host functions such as `camera_media_open`, `camera_media_write`, `camera_media_heartbeat`, and `camera_media_close`. Those functions SHALL hand off to the same native uploader used by native agent camera sources.

**Rationale**:
- One uploader implementation means one lease/drain/backpressure model.
- Plugins should not reimplement gateway session semantics.
- Binary chunk writes through the host bridge are cheaper and clearer than trying to encode media into JSON result payloads.

### Decision 6: `plugin_result` remains metadata/event oriented

**Choice**: Discovery/event plugins may continue to publish descriptors, inventory, status, and camera-originated events through `plugin_result`. Streaming plugins SHALL NOT carry live media on that path.

**Rationale**:
- Preserves compatibility with the existing ingestion pipeline.
- Keeps bulk media transport off a schema intended for bounded result payloads.

## Architecture

### Transport path
1. An operator or policy starts a camera relay session.
2. Core selects the assigned agent and sends relay-open control as it does today.
3. The agent sources media either:
   - from a native reader, or
   - from a streaming Wasm plugin using the host media bridge.
4. The agent sends media over the existing camera media gRPC service to `serviceradar-agent-gateway`.
5. The gateway authenticates the session, opens or looks up the `core-elx` relay ingress process over ERTS, and stores the returned process reference in gateway session state.
6. Media chunks are forwarded as ERTS messages/casts to that ingress process.
7. The ingress process hands chunks into the existing tracker/Membrane pipeline path.
8. Heartbeat and close control use synchronous ERTS calls to the same ingress boundary.

### Wasm streaming runtime
1. Core assigns a streaming plugin to an agent with explicit camera-stream capability and resource limits.
2. The agent starts the plugin in streaming mode under wazero with a long-lived context and cancellation handle.
3. The plugin calls `camera_media_open` to obtain a session handle.
4. The plugin writes encoded access units/chunks via `camera_media_write(handle, ptr, len, metadata)`.
5. The host bridge copies from Wasm memory into the shared native uploader.
6. The uploader manages gateway open/upload/heartbeat/close and drain semantics.
7. When the relay ends or the lease is revoked, the runtime cancels the plugin and closes the media handle.

## Risks / Trade-offs
- **Cross-node process forwarding complexity**
  - Mitigation: use a single ingress-service boundary that returns per-session process references and hide node selection behind that service.
- **Wasm memory copy overhead for media writes**
  - Mitigation: require chunk-oriented writes, avoid JSON framing, and reuse the shared native uploader for batching/backpressure.
- **Runaway streaming plugins**
  - Mitigation: separate streaming-mode admission control, explicit capability gating, and per-plugin/session resource limits.
- **Behavior drift between native and plugin camera sources**
  - Mitigation: both paths use the same uploader and the same gateway/core relay contracts.

## Migration Plan
1. Introduce `core-elx` relay ingress processes and the ERTS-facing gateway ingress client.
2. Remove gateway-to-core gRPC forwarding from the camera media path.
3. Add a streaming plugin assignment/runtime model in the agent.
4. Add media host bridge functions and connect them to the shared native uploader.
5. Update one camera-capable plugin path to use the streaming bridge as the reference implementation.
6. Add end-to-end tests that cover native source mode and streaming-plugin mode.

## Open Questions
- Should streaming plugin assignment be a new plugin capability in the existing manifest, or a distinct plugin kind with tighter scheduling rules?
- Do we want one streaming Wasm instance per relay session, or a reusable long-lived vendor session process that can serve multiple relay sessions?
