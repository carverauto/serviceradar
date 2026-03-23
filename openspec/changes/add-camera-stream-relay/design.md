# Design: Edge-routed camera stream relay

## Context
Issue `#2916` combines three concerns that need to line up:

1. Camera discovery and enrichment from vendor APIs such as AXIS VAPIX and Ubiquiti Protect.
2. A normalized core-side model for camera stream assets and state.
3. Live video delivery in the topology UI without requiring SaaS-to-camera reachability.

The third item is the architectural gap. In most customer environments, ServiceRadar cannot dial cameras directly from the control plane. The agent can reach the camera locally, and the agent already has an outbound trust path to `serviceradar-agent-gateway`. That makes camera viewing an edge-originated transport problem, not a direct-control-plane fetch problem.

The user also called out Membrane specifically. That is the right fit for the relay tier in Elixir: it gives us supervised media pipelines, stream fan-out, codec-aware processing, and browser-facing output options without turning the gateway into a media server.

## Goals / Non-Goals
- Goals:
  - Route live camera viewing through the edge agent and gateway rather than requiring direct platform access to customer cameras.
  - Integrate Membrane into `serviceradar_core_elx` as the platform relay and fan-out layer.
  - Ensure a single camera/source session can serve multiple viewers without opening duplicate upstream pulls to the camera.
  - Persist normalized camera source and stream metadata in dedicated platform-schema tables tied to canonical devices.
  - Make topology camera selection open authorized live viewers for one camera or a selected cluster.
  - Feed camera availability/activity changes into platform state so topology can react to camera health.
- Non-Goals:
  - Long-term video recording, retention, or evidence storage.
  - Browser-direct RTSP playback.
  - Direct SaaS-to-camera dialing as a required path.
  - Full Protect plugin implementation in this proposal; this change defines the relay/data-plane the plugin will target.
  - Building a general-purpose video CDN.

## Decisions

### Decision 1: Membrane lives in `serviceradar_core_elx`

**Choice**: Host the media session supervisor and Membrane pipelines in `serviceradar_core_elx`, not in `web-ng` and not in `serviceradar-agent-gateway`.

**Rationale**:
- The user explicitly wants the bulk of the work in `core-elx`.
- `core-elx` is the right place for authoritative session state, authorization checks, and data-model integration.
- `web-ng` should remain a UI/API client, not a media relay.
- `agent-gateway` should stay focused on edge trust termination and forwarding, not long-lived media processing.

### Decision 2: The agent originates camera source sessions

**Choice**: The agent pulls RTSP/vendor media locally and pushes an uplink through `serviceradar-agent-gateway` toward the Membrane relay.

**Rationale**:
- This matches the actual deployment constraint: the agent can reach the customer network; the platform usually cannot.
- It preserves the existing outbound edge connectivity model.
- It avoids adding inbound customer firewall/NAT requirements.

### Decision 3: The gateway forwards media/control traffic but does not own fan-out

**Choice**: `serviceradar-agent-gateway` authenticates and binds media sessions to an enrolled edge identity, then forwards media/control traffic to `core-elx`.

**Rationale**:
- Keeps media orchestration centralized.
- Avoids splitting session truth across gateway and core.
- Keeps gateway horizontally scalable as a transport/auth boundary instead of a transcode point.

### Decision 3a: Media uplink uses a separate service

**Choice**: Live camera media and relay-control messages use a dedicated media service/proto instead of `proto/monitoring.proto`.

**Rationale**:
- Continuous media transport has different flow control, payload sizing, and lifecycle requirements than health/status RPCs.
- This keeps the existing monitoring service readable and avoids overloading generic status/result semantics with video-specific framing.
- It lets us evolve relay-control, heartbeats, codec negotiation, and chunking independently from checker/status ingestion.

### Decision 4: Camera inventory uses dedicated relational tables

**Choice**: Store camera-specific identity and stream metadata in dedicated platform-schema tables linked to canonical device IDs.

**Minimum model**:
- `camera_sources`
  - canonical `device_id`
  - vendor (`axis`, `ubiquiti-protect`, etc.)
  - vendor camera identifier
  - management endpoint / source hints
  - assigned edge agent or gateway affinity
- `camera_stream_profiles`
  - `camera_source_id`
  - vendor profile ID / name
  - codec/container hints
  - auth mode
  - relay eligibility / freshness metadata
- `camera_stream_sessions`
  - `camera_stream_profile_id`
  - active upstream session key
  - viewer count
  - last viewer detached timestamp
  - relay state

**Rationale**:
- `ocsf_devices` remains the canonical device row.
- Camera stream assets have lifecycle and lookup patterns that do not belong in opaque metadata blobs.
- This supports both AXIS and Protect without vendor-specific sprawl in one JSON column.

### Decision 5: Discovery plugins publish descriptors, not media

**Choice**: Camera-capable plugins may publish camera source IDs, stream descriptors, auth requirements, and event payloads. They must not carry raw media frames in `plugin_result` payloads.

**Rationale**:
- `plugin_result` is for metadata, status, and event data, not continuous video transport.
- Keeping discovery/control separate from media uplink avoids abusing the status pipeline.

### Decision 6: Browser viewing is session-token based and low-latency

**Choice**: The UI requests a short-lived view session for a selected camera/profile, and the platform returns a browser-consumable relay session. The initial target is low-latency delivery suitable for deck.gl/topology embedding, with Membrane owning the packaging details.

**Rationale**:
- Browsers cannot consume RTSP directly.
- Session tokens let us bind authorization, audit, and cleanup to an explicit operator action.
- Membrane keeps the browser-facing format flexible while preserving a single upstream ingest.

## Stream Path

### 1. Discovery and inventory
- A camera discovery plugin or integration updates `camera_sources` and `camera_stream_profiles` in core.
- Each camera profile records edge affinity so the platform knows which agent can originate a live session.

### 2. Viewer session request
- The operator selects a camera in topology or device UI.
- `web-ng` calls a core API to create a live-view session for `camera_source_id + stream_profile_id`.
- Core authorizes the user, checks freshness/availability, creates a `camera_stream_session`, and allocates a relay target in `serviceradar_core_elx`.

### 3. Relay-control kickoff
- Core sends a control request to the assigned edge agent identifying:
  - camera source/profile to open,
  - relay session ID,
  - target media ingress endpoint exposed by the dedicated media service,
  - short-lived session credentials/lease.

### 4. Agent source ingest
- The agent opens the camera locally using RTSP or vendor-specific source access.
- The agent normalizes the source into the transport expected by the media service and begins streaming uplink frames/chunks/packets outward.

### 5. Gateway forwarding
- `serviceradar-agent-gateway` terminates edge mTLS for the media service.
- The gateway authenticates the agent/session binding and forwards the media uplink to the `core-elx` media ingress service.
- The gateway does not transcode, multiplex for viewers, or own session state.

### 6. Core-elx Membrane relay
- `serviceradar_core_elx` receives the uplink, attaches it to the Membrane pipeline for that relay session, and marks the upstream ingest active.
- Additional viewer requests for the same camera/profile attach to the same relay pipeline instead of causing a new agent-side pull.

### 7. Browser delivery
- Core returns a browser-consumable viewer session to `web-ng`.
- `web-ng` renders the live player in topology/device UI and renews the lease while the viewer remains active.

### 8. Teardown
- When the last viewer detaches, the relay session enters idle state.
- After the idle TTL, core instructs cleanup and the agent stops the local camera source session.

### Decision 7: Idle relay sessions are torn down aggressively

**Choice**: When the last viewer leaves, the platform tears down the upstream session after a short idle TTL rather than keeping camera sessions open indefinitely.

**Rationale**:
- Protects customer bandwidth and camera resources.
- Prevents abandoned UI tabs from pinning long-lived media sessions.

## Risks / Trade-offs
- **Bandwidth pressure on the edge uplink**
  - Mitigation: bound concurrent sessions per agent/gateway, prefer one upstream per camera profile, expose relay metrics.
- **Codec mismatch across camera vendors**
  - Mitigation: define a supported codec/profile MVP and surface incompatible streams as unavailable rather than silently failing.
- **Session leak risk**
  - Mitigation: short-lived viewer tokens, heartbeat/lease expiry, and idle teardown.
- **Core-elx operational complexity**
  - Mitigation: isolate Membrane under a dedicated supervisor tree and publish health/usage telemetry.
- **UI overload when a cluster contains many cameras**
  - Mitigation: cap concurrent live tiles, lazy-load visible tiles, and show placeholder state for the rest.

## Migration Plan
1. Add normalized camera tables/resources in `platform` schema and expose read APIs.
2. Extend plugin/device ingestion so AXIS/Protect-style discovery populates those tables.
3. Add a dedicated media service/proto for session control and agent-originated uplink paths through gateway to `core-elx`.
4. Add Membrane relay supervision and single-upstream/multi-viewer fan-out.
5. Add topology/device viewer flows in `web-ng`.
6. Add event/state wiring so camera availability and activity update topology/UI surfaces.

## Open Questions
- Which browser-facing transport should be the first-class MVP output from Membrane for the topology canvas?
- Do we need codec transcoding in the MVP, or do we initially accept only supported passthrough codecs/profiles?
