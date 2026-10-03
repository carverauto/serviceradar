# Change: Add a TURN relay and per-viewer ICE credentials for WebRTC viewers

## Why
Camera relay WebRTC viewers get only credential-free STUN endpoints. When a
viewer sits behind a symmetric NAT or a restrictive firewall, no
server-reflexive candidate pair works and ICE ends in `connection_failed`.
On a deployment configured this way, viewer ICE failures were the trigger
for camera relay viewer sessions dying. Each failure was made worse by
separate pipeline-isolation bugs (tracked in #5040), but the ICE failure
itself has no remedy without a relay.

Remote desktop (RDP) already mints short-lived TURN REST credentials in
web-ng from a mounted shared secret, but that code is RDP-only. The camera
relay cannot use it. No deployment option ships a TURN server, and no
backend exists for a managed TURN service.

## What Changes
- Add a shared **ICE credential provider** in `serviceradar_core` with two
  backends:
  - `static_secret`: TURN REST API HMAC credentials from a file-mounted
    shared secret. This is the scheme RDP already uses, lifted out of
    web-ng.
  - `cloudflare`: short-lived credentials minted per viewer through
    Cloudflare's TURN key API, fetched via `ServiceRadar.HTTP.EgressClient`.
- Use the provider for **both** camera relay WebRTC viewers and remote
  desktop WebRTC. Each viewer session gets its own minted credential, and
  the browser and core-elx's ExWebRTC peer each get only what they need.
- Keep the existing rule that static ICE configuration carries URLs only.
  No username, credential or secret is accepted in Helm values, ICE JSON or
  browser input.
- Add an **optional TURN server** to the Helm chart (eturnal, recommended in
  `design.md`):
  - UDP and TCP 3478, optional TLS 5349, and a bounded relay port range.
  - Exposed through a LoadBalancer or NodePort Service with a configurable
    external address.
  - Wired to the same operator-owned shared-secret Secret.
  - Denies relaying to cluster and private CIDRs by default.
- Add chart configuration for the Cloudflare backend (key ID plus an
  operator-owned token Secret) and render-time validation for both backends.
- Define failure behavior: when the provider cannot mint, the viewer falls
  back to STUN-only ICE and then the websocket transports, and the failure
  is visible to operators.
- Add telemetry for mint successes and failures and for which ICE candidate
  type each viewer connected with.

## Impact
- Affected specs:
  - `camera-streaming`: viewer ICE credentials, fallback.
  - New capability `webrtc-ice-relay`: provider, backends, TURN server,
    secrets, observability.
- Affected code:
  - New provider modules under `elixir/serviceradar_core/lib/serviceradar/webrtc/`.
  - `elixir/web-ng/lib/serviceradar_web_ng/{camera_relay_webrtc.ex,remote_desktop_webrtc.ex,remote_desktop_webrtc_config.ex}`.
  - `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/camera_relay/{pipeline.ex,webrtc_signaling_manager.ex}`.
  - `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/remote_desktop/data_channel_provider.ex`.
  - Helm `templates/` (TURN server Deployment, Service, ConfigMap and
    NetworkPolicy; Secret mounts), `values.yaml`, `values-demo.yaml`.
- Secrets: the TURN shared secret and the Cloudflare API token are
  ServiceRadar infrastructure secrets (Kubernetes Secret or OpenBao), **not**
  device or integration credentials. They do not belong in
  `platform.network_credential_secrets`; see `design.md`.
- Compatibility:
  - The pending `add-remote-access-desktop-rdp` requirement
    "TURN credentials are short-lived and file-backed" stays satisfied: the
    `static_secret` backend is that behavior.
  - The existing `remoteAccess.desktop.rdp.webRTC.turn` values keep working
    and map onto the shared configuration.
