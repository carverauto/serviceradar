# Tasks: Edge-routed camera stream relay

## 1. Data model and core contracts
- [ ] 1.1 Create platform-schema migrations for normalized camera inventory tables linked to canonical device IDs.
- [ ] 1.2 Add Ash resources/actions for camera sources, stream profiles, and relay sessions in `elixir/serviceradar_core`.
- [ ] 1.3 Expose read APIs for camera inventory, stream profiles, and current relay state.
- [ ] 1.4 Extend plugin ingestion so camera discovery updates normalized camera inventory atomically.

## 2. Edge media transport
- [ ] 2.1 Define a dedicated camera media service/proto for relay control, heartbeats, and media uplink between agent, gateway, and `core-elx`.
- [ ] 2.2 Implement agent-side camera source workers that open local RTSP/vendor streams and push uplinks outward.
- [ ] 2.3 Implement gateway authentication/binding and forwarding for camera media/control sessions.
- [ ] 2.4 Enforce per-agent and per-gateway limits for concurrent camera relay sessions.

## 3. Membrane integration in `serviceradar_core_elx`
- [ ] 3.1 Add Membrane dependencies and supervision tree integration in `elixir/serviceradar_core_elx`.
- [ ] 3.2 Implement a relay session manager that binds camera stream sessions to Membrane pipelines.
- [ ] 3.3 Reuse a single upstream ingest for concurrent viewers of the same camera/profile.
- [ ] 3.4 Add idle TTL teardown, failure recovery, and relay health telemetry.

## 4. UI and topology integration
- [ ] 4.1 Add topology payload fields and APIs needed to identify camera-capable endpoint nodes.
- [ ] 4.2 Add God-View interactions for opening a live viewer from a camera node.
- [ ] 4.3 Add tiled multi-camera viewing for selected camera clusters with bounded concurrency.
- [ ] 4.4 Show unavailable/auth-required/relay-error states in the viewer UX.

## 5. Camera events and state propagation
- [ ] 5.1 Ingest Protect/AXIS-style camera activity and availability events into platform event/state surfaces.
- [ ] 5.2 Publish camera availability changes to topology/UI refresh paths.
- [ ] 5.3 Ensure camera-originated events can be correlated back to canonical devices and stream profiles.

## 6. Tests and verification
- [ ] 6.1 Add unit tests for camera inventory upsert and relay session lifecycle.
- [ ] 6.2 Add integration tests for agent -> gateway -> core media session negotiation.
- [ ] 6.3 Add UI tests for topology camera selection and live viewer behavior.
- [ ] 6.4 Add failure tests for unreachable cameras, stale sessions, and unauthorized viewers.
- [ ] 6.5 Run `openspec validate add-camera-stream-relay --strict`.
