# Change: Add edge-routed camera stream relay with Membrane in core-elx

## Why
GitHub issue [#2916](https://github.com/carverauto/serviceradar/issues/2916) asks for camera nodes in the topology view, live camera feeds on the deck.gl canvas, Ubiquiti Protect support, AXIS compatibility, and event/status integration into ServiceRadar.

We already have related proposal work for AXIS camera discovery via the Wasm plugin system, but that work stops at metadata, stream descriptors, and event extraction. It does not define how live video reaches operators. In real deployments, the platform usually does not have direct network reachability to customer cameras. Cameras sit behind customer routing and NAT, while the agent can reach them locally and can always push traffic outward through `serviceradar-agent-gateway`.

If each browser session opens its own camera connection, we will multiply load on the camera and make remote viewing fragile. We need an edge-first streaming architecture where the agent pulls camera media locally, pushes a media uplink to the platform, and `core-elx` uses Membrane to relay and fan out one upstream session to many viewers.

## What Changes
- Add a new `camera-streaming` capability that defines:
  - edge-originated camera media uplinks,
  - Membrane-managed relay/fan-out in `serviceradar_core_elx`,
  - authorized viewer session creation and teardown,
  - single-upstream/multi-viewer behavior for the same camera stream.
- Normalize camera media inventory into dedicated platform-schema records linked to canonical devices instead of relying on ad hoc JSON metadata in `ocsf_devices`.
- Extend edge transport so agents can start camera source sessions locally and push media through `serviceradar-agent-gateway` without requiring direct platform-to-camera connectivity.
- Add a dedicated camera media service/transport for live video uplink and relay control instead of extending the generic monitoring status/results service.
- Extend plugin result contracts so Protect/AXIS-style discovery can publish camera source and stream descriptors, but not raw media bytes or secrets.
- Add topology/UI requirements for selecting one or more camera nodes and opening a live tiled viewer from the God-View experience.
- Carry camera availability and camera-originated events into ServiceRadar state/event surfaces so topology can react to camera health and activity.

## Impact
- Affected specs:
  - `camera-streaming` (new)
  - `edge-architecture` (modified)
  - `device-inventory` (modified)
  - `wasm-plugin-system` (modified)
  - `build-web-ui` (modified)
- Affected code:
  - `elixir/serviceradar_core_elx/**`
  - `elixir/serviceradar_core/**`
  - `elixir/serviceradar_agent_gateway/**`
  - `go/cmd/agent/**`
  - `proto/monitoring.proto`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/topology_live/**`
  - `elixir/serviceradar_core/priv/repo/migrations/**`
- Related proposals:
  - Builds on `add-axis-vapix-wasm-plugin` for AXIS discovery/enrichment.
  - Provides the relay/data-model foundation needed for future Ubiquiti Protect plugin work.
