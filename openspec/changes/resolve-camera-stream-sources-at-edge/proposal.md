# Change: Resolve camera stream sources at the edge and stop storing stream secrets

## Why

Core stores camera stream addresses in plaintext, outside the unified credential
model. A UniFi Protect RTSP(S) address carries a path alias that works as a
bearer token: anyone who can reach the controller and knows the alias can watch
the camera. Other camera addresses can carry `user:password@`. Copies sit in
`platform.camera_stream_profiles.source_url_override`, profile `metadata`
(`rtsp_alias`, `rtsps_alias`), `platform.camera_sources.source_url`, device
`metadata` (`camera_source_url`, which `in:devices` returns to any `devices.view`
user), and every stored plugin result (`platform.service_status.details`,
`platform.service_state.message`). Core reads the address for one purpose only:
to copy it into the agent's `camera.open_relay` command.

Core does not need the address at all. The agent's plugin assignment that
discovered the camera already holds the integration credential and can re-derive
the address from the controller or camera when a stream opens.

## What Changes

- **Edge resolution.** On `camera.open_relay`, Core sends no address. It sends
  the identity of the discovering plugin assignment and the vendor camera and
  profile ids. The agent asks that assignment's plugin to resolve the address,
  keeps the result in memory for the session only, and opens the stream with its
  native RTSP reader. UniFi Protect and Axis plugins implement the resolver.
- **No secret at rest.** One reduction rule (design D2) runs on every plugin
  result when it enters Core, before anything is persisted or handled. RTSP
  addresses become an origin (scheme, host, port). Alias keys are removed. Any
  URL loses its userinfo. Inventory keeps only non-secret facts:
  `source_origin` on the profile and `discovery_assignment_id` on the source.
- **BREAKING (schema):** `camera_sources.source_url` and
  `camera_stream_profiles.source_url_override` are removed from the resources,
  emptied by a cleanup job, and then dropped one release later.
- **BREAKING (version skew):** Core does not dispatch a relay to an agent that
  lacks the `camera_source_resolution` capability. The session fails with the
  classified reason `agent_upgrade_required`.
- **Cleanup.** An Oban job, enqueued from a migration, removes every existing
  copy. It repeats passes until a pass finds nothing, and that pass must start
  after every Core node runs this change. Operators check the result with the
  worker's `pending/0`, which must return zero for every target.
- **Containment first.** Stage 1 is a Core and web-ng change only, with no agent
  or plugin release. It hides the two columns from every reader except the relay
  resolver and removes the other copies. It is not the fix: the addresses stay
  at rest in those two columns until Stage 3.

## Impact

- Affected specs: `camera-streaming`, `unifi-protect-camera-plugin`.
- Affected code: `elixir/serviceradar_core/lib/serviceradar/camera/`
  (`inventory_ingestor.ex`, `relay_source_resolver.ex`, `source.ex`,
  `stream_profile.ex`), `observability/plugin_result_ingestor.ex`,
  `edge/agent_command_bus.ex`, web-ng `device_live/camera_components.ex` and
  `topology/god_view_stream.ex` with `rendering_selection_methods.js`,
  `go/pkg/agent/` (`camera_relay*.go`, `control_stream.go`,
  `plugin_runtime_manager.go`, `push_loop_capabilities.go`),
  `go/cmd/wasm-plugins/unifi-protect/`, `go/cmd/wasm-plugins/axis/`, the
  `serviceradar-sdk-go` camera helpers, migrations, and the Helm
  `core.migrations.expectedVersion` value.
- Depends on PR #6703 (`fix/camera-relay-start-failure-reason`). That PR provides
  the classified relay failure reason, the command-record redaction and
  `SecretTextScrubber`. This change adds failure classes to that set.
- Not affected: the Wasm `stream_camera` media path (Core never selects it today),
  SRQL `in:camera_sources` (it already omits addresses), and recording playback.
