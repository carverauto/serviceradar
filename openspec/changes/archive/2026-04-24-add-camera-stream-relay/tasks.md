# Tasks: Edge-routed camera stream relay

## 1. Data model and core contracts
- [x] 1.1 Create platform-schema migrations for normalized camera inventory tables linked to canonical device IDs.
- [x] 1.2 Add Ash resources/actions for camera sources, stream profiles, and relay sessions in `elixir/serviceradar_core`.
- [x] 1.3 Expose read APIs for camera inventory, stream profiles, and current relay state.
- [x] 1.4 Extend plugin ingestion so camera discovery updates normalized camera inventory atomically.

## 2. Edge media transport
- [x] 2.1 Define a dedicated camera media service/proto for relay control, heartbeats, and media uplink between agent, gateway, and `core-elx`.
- [x] 2.2 Implement agent-side camera source workers that open local RTSP/vendor streams and push uplinks outward.
- [x] 2.3 Implement gateway authentication/binding and forwarding for camera media/control sessions.
- [x] 2.4 Enforce per-agent and per-gateway limits for concurrent camera relay sessions.

## 3. Membrane integration in `serviceradar_core_elx`
- [x] 3.1 Add Membrane dependencies and supervision tree integration in `elixir/serviceradar_core_elx`.
- [x] 3.2 Implement a relay session manager that binds camera stream sessions to Membrane pipelines.
- [x] 3.3 Reuse a single upstream ingest for concurrent viewers of the same camera/profile.
- [x] 3.4 Add idle TTL teardown, failure recovery, and relay health telemetry.

## 4. UI and topology integration
- [x] 4.1 Add topology payload fields and APIs needed to identify camera-capable endpoint nodes.
- [x] 4.2 Add God-View interactions for opening a live viewer from a camera node.
- [x] 4.3 Add tiled multi-camera viewing for selected camera clusters with bounded concurrency.
- [x] 4.4 Show unavailable/auth-required/relay-error states in the viewer UX.

## 5. Camera events and state propagation
- [x] 5.1 Ingest Protect/AXIS-style camera activity and availability events into platform event/state surfaces.
- [x] 5.2 Publish camera availability changes to topology/UI refresh paths.
- [x] 5.3 Ensure camera-originated events can be correlated back to canonical devices and stream profiles.

## 6. Tests and verification
- [x] 6.1 Add unit tests for camera inventory upsert and relay session lifecycle.
- [x] 6.2 Add integration tests for agent -> gateway -> core media session negotiation.
- [x] 6.3 Add UI tests for topology camera selection and live viewer behavior.
- [x] 6.4 Add failure tests for unreachable cameras, stale sessions, and unauthorized viewers.
- [x] 6.5 Run `openspec validate add-camera-stream-relay --strict`.
