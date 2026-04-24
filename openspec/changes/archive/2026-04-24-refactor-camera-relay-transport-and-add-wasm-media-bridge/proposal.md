# Change: Refactor camera relay transport and add Wasm media bridge

## Why
The current camera relay path uses a dedicated gRPC service from the edge agent into `serviceradar-agent-gateway`, and then another gRPC hop from `serviceradar-agent-gateway` into `serviceradar_core_elx`. That works, but it diverges from the normal ServiceRadar gateway pattern where edge traffic terminates at the gateway and platform-internal coordination moves over ERTS.

At the same time, the current Wasm plugin runtime is built for bounded plugin executions that emit `plugin_result` payloads. It can discover cameras and publish descriptors, but it cannot own a long-lived live-media session. If camera vendors are expected to stream live video through Wasm plugins, we need a separate streaming plugin mode and a real host bridge for live media. We should not overload `submit_result` or the one-shot plugin runtime with bulk media transport.

## What Changes
- Replace the current `agent-gateway -> core-elx` camera media gRPC forwarding hop with an ERTS-native ingress boundary.
- Keep the edge-facing `agent -> agent-gateway` camera media transport on the existing dedicated gRPC service.
- Add a per-relay-session ingress process model in `serviceradar_core_elx` so the gateway can forward media chunks and control messages over ERTS without per-chunk RPC calls.
- Add a separate Wasm streaming plugin mode in the agent for long-lived camera media sessions, distinct from the current scheduled/plugin-result execution mode.
- Add a Wasm host bridge for live media session lifecycle and chunk writes, backed by the same native camera relay uploader used by non-plugin media sources.
- Keep plugin-result ingestion focused on descriptors, metadata, status, and events; live media bytes stay off the `plugin_result` path.

## Impact
- Affected specs:
  - `camera-streaming` (new)
  - `edge-architecture` (modified)
  - `wasm-plugin-system` (modified)
- Affected code:
  - `elixir/serviceradar_agent_gateway/**`
  - `elixir/serviceradar_core_elx/**`
  - `go/pkg/agent/**`
  - `go/cmd/wasm-plugins/**`
  - `proto/camera_media.proto`
- Related changes:
  - Builds on `add-camera-stream-relay`
  - Builds on `harden-camera-relay-production-readiness`
