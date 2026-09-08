# Restore UniFi Protect Camera Streams

## Why

UniFi Protect camera streams are not working on demo. Investigation established:
the agent relays camera media via its **native RTSP client** (`gortsplib`,
`camera_relay_rtsp.go`), not the `unifi-protect-camera-stream` WASM plugin (the
stream plugin is only used when the relay-open command carries a
`plugin_assignment_id`, which nothing sets). So "streams working" requires: the
inventory plugin (integration API, `X-API-Key`, `/proxy/protect/integration/v1/
cameras` + `/rtsps-stream`) placing a reachable `rtsps://` `source_url` into a
`Camera.Source`; the source having `assigned_agent_id` + `assigned_gateway_id`
and a relay-eligible `StreamProfile`; the assigned agent reaching the controller
RTSPS port with `insecure_skip_verify`; and a viewer transport enabled (WebRTC
default-off, or the WebCodecs fallback). Current demo state: the plugin
assignments were disabled/stale (0.1.0) and the credential-rules UI cannot create
a UniFi `api_key` rule with a static controller host.

## What Changes

- Ship the current unifi-protect plugin (0.1.1 static-controller-host override)
  and bind/enable the inventory assignment.
- Create the UniFi Protect camera-inventory + camera-stream credential rules
  DB-backed (api_key `CWPz3M1WFHVqkE37gPKQkgTRPTNBJqv0`, `metadata.host`
  `192.168.1.1`, a `target_query` that resolves a device owned by the streaming
  agent — not `metadata.vendor:"Ubiquiti"` which matches 0).
- Confirm inventory writes `source_url` + agent/gateway assignment +
  `relay_eligible`; enable a viewer transport (`:camera_relay_webrtc_enabled` or
  the WebCodecs fallback).
- Verify a live stream renders end to end against controller `192.168.1.1`.

## Impact

- Affected specs: `unifi-protect`.
- Affected code: `go/cmd/wasm-plugins/unifi-protect/`, camera relay
  (`camera_relay*.go`, `relay_session_manager.ex`, `camera_multiview.ex`),
  credential materializer (`unifi_protect_profile.ex`).
- Depends on `unify-plugin-credential-rules-db-surface` (api_key/camera auth in
  the credential-rules UI).
