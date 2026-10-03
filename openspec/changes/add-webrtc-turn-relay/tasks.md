## 1. ICE credential provider
- [ ] 1.1 Add the `ServiceRadar.WebRTC.IceCredentials` behaviour and dispatcher in `serviceradar_core`, with subject binding, TTL bounds (60..3600s, default 600s) and per-actor/per-session mint rate limits.
- [ ] 1.2 Implement the `static_secret` backend (TURN REST HMAC) by moving RDP's minting and file-backed secret loader out of web-ng. RDP tests must pass unchanged, and credentials must be byte-identical for the same inputs.
- [ ] 1.3 Implement the `cloudflare` backend over `ServiceRadar.HTTP.EgressClient`, with a file-backed token, a 5s timeout, URL-scheme validation of the returned servers, and no logging of the token or credentials.
- [ ] 1.4 Add telemetry for mint results and for the selected candidate-pair type, routed through JetStream.

## 2. Feature wiring
- [ ] 2.1 Camera relay: web-ng signaling returns minted ICE servers per viewer session, or the STUN-only list plus `ice_credentials: "unavailable"` on failure.
- [ ] 2.2 Camera relay: the core-elx ExWebRTC peer gets server-side minted credentials using the in-cluster TURN Service URL.
- [ ] 2.3 Remote desktop: call the provider. Existing `remoteAccess.desktop.rdp.webRTC.turn` values keep working.
- [ ] 2.4 Add the `forceRelay` option (browser `iceTransportPolicy: relay`), rejected when the backend is `none`.
- [ ] 2.5 Add an ICE health indicator to the camera relay and remote desktop settings.

## 3. Helm
- [ ] 3.1 Add `webrtc.iceCredentials` values (backend, TTL, forceRelay, `static_secret` Secret reference, Cloudflare key ID and token Secret reference) with render-time validation that fails on missing Secrets, keys or out-of-range TTLs.
- [ ] 3.2 Add an optional eturnal `turnServer` component: Deployment, Service (LoadBalancer or NodePort; UDP/TCP 3478, optional TLS 5349, bounded relay range), required `externalAddress`, a peer deny list covering private, loopback, link-local, CGNAT, ULA and the cluster CIDRs, and a NetworkPolicy.
- [ ] 3.3 Generalize RDP's core-only WebRTC egress NetworkPolicy to `webrtc.networkPolicy` and alias the RDP keys to it.
- [ ] 3.4 Add Helm unittest coverage: backend validation, Secret mounts reaching only web-ng and core, TURN server rendering, the deny list, and the alias compatibility.

## 4. Docs and rollout
- [ ] 4.1 Add an operator guide for both backends, including the Smokescreen ACL entry `rtc.live.cloudflare.com` for Cloudflare and the ports to expose for self-hosted TURN.
- [ ] 4.2 Enable on demo with the chosen backend, then verify that viewers behind a symmetric NAT connect over relay candidates and that relay-type selection appears in telemetry.
