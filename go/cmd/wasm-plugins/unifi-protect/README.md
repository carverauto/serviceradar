# UniFi Protect Camera Plugin

ServiceRadar TinyGo/WASM plugin for UniFi Protect cameras.

## Current Scope
- Protect controller bootstrap polling for camera inventory
- Normalized camera descriptors and stream profile metadata
- Optional API-key, cookie, or local-account login bootstrap for controller access
- Narrow `stream_camera` entrypoint that resolves RTSP or RTSPS stream aliases and relays media through the existing Wasm camera media bridge

## Build

```bash
./build.sh
```

Output:
- `bazel-bin/build/wasm_plugins/unifi_protect_camera_bundle.zip`
- `bazel-bin/build/wasm_plugins/unifi_protect_camera_bundle.sha256`
- `bazel-bin/build/wasm_plugins/unifi_protect_camera_stream_bundle.zip`
- `bazel-bin/build/wasm_plugins/unifi_protect_camera_stream_bundle.sha256`

The same Wasm artifact exports both bundle variants:
- `run_check` for discovery/status/inventory polling
- `stream_camera` for live-media relay bootstrap

Each bundle contains the canonical import shape:
- `plugin.yaml`
- `plugin.wasm`
- optional `config.schema.json`

## Config

```json
{
  "host": "udm.example.local",
  "scheme": "https",
  "username": "local-admin",
  "password": "secret",
  "insecure_skip_verify": true,
  "timeout": "10s",
  "bootstrap_path": "/proxy/protect/api/bootstrap",
  "login_path": "/api/auth/login",
  "rtsp_port": 7447
}
```

## Notes
- This first slice targets the common Protect bootstrap path and RTSP relay alias discovery.
- The current live-media path is intentionally narrow: RTSP alias resolution and interleaved RTP-over-RTSP transport over the existing shared SDK + media bridge.
- Discovery prefers the Protect integration camera API on newer controllers for every auth mode, and falls back to the legacy bootstrap route when the integration endpoint is unavailable.
- API-key discovery on newer controllers may return `rtsps://` stream URLs; the current shared SDK transport now supports those sources.
- Set `insecure_skip_verify: true` when the controller or RTSPS relay uses a self-signed certificate.
- When `relay.source_url` is absent, the streaming path requires both `relay.camera_source_id` and `relay.stream_profile_id`; it does not guess across the bootstrap payload.
- If Protect omits a per-camera host in bootstrap, RTSP alias fallback uses the configured controller host.
- Future slices can expand event ingestion and broader controller auth/session variants without changing the host ABI.

## Live Controller Smoke Test

You can validate the plugin against a real Protect controller with the gated Go smoke test:

```bash
cd go/cmd/wasm-plugins/unifi-protect

UNIFI_PROTECT_LIVE_HOST=udm.example.local \
UNIFI_PROTECT_LIVE_SCHEME=https \
UNIFI_PROTECT_LIVE_USERNAME=local-admin \
UNIFI_PROTECT_LIVE_PASSWORD=secret \
UNIFI_PROTECT_LIVE_INSECURE=1 \
UNIFI_PROTECT_LIVE_COLLECT_EVENTS=1 \
UNIFI_PROTECT_LIVE_CAMERA_SOURCE_ID=<camera-id-or-mac> \
UNIFI_PROTECT_LIVE_STREAM_PROFILE_ID=<channel-id-or-name> \
go test -run TestProtectLiveControllerSmoke -v
```

Supported auth inputs:
- `UNIFI_PROTECT_LIVE_API_KEY`
- `UNIFI_PROTECT_LIVE_COOKIE`
- or `UNIFI_PROTECT_LIVE_USERNAME` + `UNIFI_PROTECT_LIVE_PASSWORD`

Useful optional inputs:
- `UNIFI_PROTECT_LIVE_BOOTSTRAP_PATH`
- `UNIFI_PROTECT_LIVE_LOGIN_PATH`
- `UNIFI_PROTECT_LIVE_TIMEOUT`
- `UNIFI_PROTECT_LIVE_RTSP_PORT`
- `UNIFI_PROTECT_LIVE_EVENT_SOURCES`
- `UNIFI_PROTECT_LIVE_INSECURE=1` for self-signed TLS during local validation
