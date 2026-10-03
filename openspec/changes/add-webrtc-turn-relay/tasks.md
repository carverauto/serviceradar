## 1. ICE credential provider
- [ ] 1.1 Add the `ServiceRadar.WebRTC.IceCredentials` behaviour and dispatcher in `serviceradar_core`, with subject binding, TTL bounds (60..3600s, default 600s) and per-actor/per-session mint rate limits.
- [ ] 1.2 Implement the `static_secret` backend (TURN REST HMAC) by moving RDP's minting and file-backed secret loader out of web-ng. RDP tests must pass unchanged, and credentials must be byte-identical for the same inputs.
- [ ] 1.3 Implement the `cloudflare` backend over `ServiceRadar.HTTP.EgressClient`, reading the TURN key ID from the relay settings and the key secret from the credential store, with a 5s timeout, URL-scheme validation of the returned servers, and no logging of tokens or credentials.
- [ ] 1.4 Publish mint and candidate-pair metrics on `metrics.timeseries.webrtc.*` (generic timeseries shape) from web-ng and core-elx.

## 1A. Cloudflare bring-your-own provisioning
- [ ] 1A.1 Add the native credential descriptor `cloudflare` (auth `api_token`; purposes `turn_provisioning`, `turn_key`), keeping `supports_rules: true`.
- [ ] 1A.2 Add the deployment-level WebRTC relay settings resource (backend, TTL, forceRelay, Cloudflare account/key ids, provisioning status) with direct `on_delete: :restrict` references to the API-token and TURN-key secrets.
- [ ] 1A.3 Register the settings as a direct consumer in `CredentialUsage`, and cover both references in `GuardCredentialDestroy`; the credential usage view links to the settings page.
- [ ] 1A.4 Add RBAC permissions `settings.webrtc.manage` and `settings.webrtc.view` to the core catalog.
- [ ] 1A.5 Add the Oban provisioning job: resolve account, create the TURN key through `EgressClient`, store its secret, switch settings; name keys by deployment and attempt id for idempotency; delete the key on partial failure, else record `orphaned_key` and retry cleanup; rotate and revoke actions.
- [ ] 1A.6 Add web-ng Settings -> Media relay (TURN) (`/settings/webrtc`, settings catalog entry) with backend choice, credential pick/create, Provision/Rotate/Revoke and status with reason class.
- [ ] 1A.7 Add the settings API used by automation (set backend and credential reference, trigger provisioning, read status).

## 1B. Usage dashboard
- [ ] 1B.1 Add the Cloudflare usage poller (Oban cron, 15 min, `:integrations`) publishing TURN usage samples to `metrics.timeseries.webrtc.cloudflare`; confirm the GraphQL dataset and fields against Cloudflare's schema.
- [ ] 1B.2 Grant core and web-ng NATS publish on `metrics.timeseries.webrtc.>` in both Helm auth modes and compose; add a chart unittest for the grants.
- [ ] 1B.3 Add the SRQL-backed usage panel (relay share, mint failures by reason, Cloudflare bytes per day, 30-day trend) and the relay-bytes threshold alert.

## 2. Feature wiring
- [ ] 2.1 Camera relay: web-ng signaling returns minted ICE servers per viewer session, or the STUN-only list plus `ice_credentials: "unavailable"` on failure.
- [ ] 2.2 Camera relay: the core-elx ExWebRTC peer gets server-side minted credentials using the in-cluster TURN Service URL.
- [ ] 2.3 Remote desktop: call the provider. Existing `remoteAccess.desktop.rdp.webRTC.turn` values keep working.
- [ ] 2.4 Add the `forceRelay` option (browser `iceTransportPolicy: relay`), rejected when the backend is `none`.
- [ ] 2.5 Add an ICE health indicator to the camera relay and remote desktop settings.

## 3. Helm
- [ ] 3.1 Add `webrtc.iceCredentials` values for infrastructure only (the `static_secret` Secret reference and its TTL bounds) with render-time validation that fails on missing Secrets, keys or out-of-range TTLs. No Cloudflare token value exists.
- [ ] 3.2 Add an optional eturnal `turnServer` component: Deployment; exposure via shared Envoy Gateway routes (UDPRoute/TCPRoute 3478, passthrough TLSRoute 5349 with a cert-manager Certificate) or a LoadBalancer/NodePort Service; required `externalHostname`; in-cluster-only bounded relay range; a peer deny list covering private, loopback, link-local, CGNAT, ULA and the cluster CIDRs with allows for the server's own relay addresses and core-elx pods; a NetworkPolicy (client ports from the gateway, relay ports from core-elx only).
- [ ] 3.3 Generalize RDP's core-only WebRTC egress NetworkPolicy to `webrtc.networkPolicy` and alias the RDP keys to it.
- [ ] 3.4 Add Helm unittest coverage: backend validation, Secret mounts reaching only web-ng and core, TURN server rendering, the deny list, and the alias compatibility.

## 4. Docs and rollout
- [ ] 4.1 Add an operator guide for both backends: the Cloudflare token permissions and the Settings flow, the Smokescreen ACL entries `api.cloudflare.com` and `rtc.live.cloudflare.com`, the automation API path, and the listeners to expose for self-hosted TURN.
- [ ] 4.2 Enable on demo with the chosen backend, then verify that viewers behind a symmetric NAT connect over relay candidates and that relay-type selection appears in telemetry.
