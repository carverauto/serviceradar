## Context
Two features negotiate WebRTC between a browser and an ExWebRTC peer that
runs in core-elx (the `serviceradar-core` pods):

- **Camera relay viewers**: `camera_relay/pipeline.ex` and
  `webrtc_signaling_manager.ex`. web-ng's `camera_relay_webrtc.ex` serves the
  ICE list and relays signaling.
- **Remote desktop (RDP)**: `remote_desktop/data_channel_provider.ex`.
  web-ng's `remote_desktop_webrtc.ex` and `remote_desktop_webrtc_config.ex`
  load the ICE JSON and the TURN shared secret and mint credentials.

The camera relay gets STUN only. RDP already implements TURN REST HMAC
minting, with a file-mounted secret, a session-bound username and a TTL of
at most one hour, but only for itself. No deployment option ships a TURN
server.

Constraints:
- Single deployment, no multitenancy.
- External fetches go through `ServiceRadar.HTTP.EgressClient`.
- The repository credential rule separates device and integration
  credentials (CNPG unified model) from ServiceRadar-to-itself secrets
  (Kubernetes Secret or OpenBao).

## Goals / Non-Goals
- Goals:
  - One provider that both features use.
  - Two backends: self-hosted TURN REST HMAC, and Cloudflare TURN.
  - An optional chart-managed TURN server.
  - Fail-soft behavior that operators can see.
  - The shared secret never reaches a browser, log or record.
- Non-Goals:
  - SFU or media mixing.
  - Recording through TURN.
  - Per-user TURN quotas beyond rate limiting.
  - Multi-region TURN selection.
  - Making TURN mandatory.

## Decisions

### Provider location and interface
- **Interface:** `ServiceRadar.WebRTC.IceCredentials`, a behaviour plus a
  dispatcher in `serviceradar_core`. Both the web-ng and core-elx releases
  load it.
  `mint(subject, opts) :: {:ok, %{ice_servers: [...], expires_at: DateTime.t()}} | {:error, reason}`.
- **Subject:** the subject binds the credential to one viewer:
  `{feature, session_id, viewer_id}`. The TURN username embeds the expiry
  and a non-reversible digest of the subject, never raw user or session
  identifiers.
- **web-ng mints for the browser.** It already authorizes the viewer and
  owns the signaling endpoint. The minted servers go into the signaling
  response only, not into page assigns rendered for every viewer.
- **Core-elx mints for its own ExWebRTC peer** with a server-side subject.
  It configures the peer with `ice_transport_policy: :all`, so host and
  server-reflexive candidates are tried first and the relay is a fallback.
- **Why the core peer needs credentials too:** when the browser alone
  relays, core must still reach the TURN server's public relay address.
  Inside a cluster that is a hairpin through the load balancer, which is not
  always routable. A core-side allocation on the in-cluster TURN Service
  avoids it.
- **Move RDP over:** RDP's existing minting (`turn_credential/2`, the TTL
  bounds, the file-backed secret loader) moves into the provider's
  `static_secret` backend, and RDP calls the provider. Its behavior and
  values keys do not change.

### Backends
- **`static_secret`** (TURN REST API, the coturn `use-auth-secret` and
  eturnal `secret` scheme):
  - `username = "<unix_expiry>:<subject_digest>"`.
  - `credential = base64(HMAC-SHA1(secret, username))`. SHA-1 is required
    by the TURN REST scheme that servers verify.
  - TTL default 600s, bounded to 60..3600s.
  - The secret is read from a mounted Secret file, 32..512 bytes, the same
    bounds RDP enforces today.
- **`cloudflare`**:
  - Call `POST https://rtc.live.cloudflare.com/v1/turn/keys/<key_id>/credentials/generate-ice-servers`
    with a bearer API token and `{"ttl": <seconds>}`, through
    `EgressClient`, so the Smokescreen proxy applies.
  - The response's `iceServers` (with username and credential) is passed
    through after URL-scheme validation.
  - The token is read from a mounted Secret file.
  - TTL default 600s, bounded as above.
  - Request timeout 5s.
  - No caching across viewers: credentials are per viewer.
- **Selection:** a deployment selects one backend
  (`webrtc.iceCredentials.backend: none|static_secret|cloudflare`, default
  `none`). STUN URLs from the static ICE list are always appended.

### Why these secrets are not in the unified credential model
The TURN shared secret and the Cloudflare TURN token authenticate
ServiceRadar to its **own media-relay infrastructure**, the same class as
NATS creds, session and JWT keys, and the Dgraph ACL credential. They are
not used to talk to a monitored device or a third-party data source
integration. They are not scoped to any target. They have exactly one
consumer: the deployment's WebRTC stack.

Storing them in `platform.network_credential_secrets` would expose them in
the operator credential inventory and rule binding UI, where they cannot be
meaningfully bound. They therefore live in an operator-owned Kubernetes
Secret (or OpenBao-synced Secret), mounted as a file into the web-ng and
core-elx pods only.

### ICE transport policy
- Default `:all` on both sides, with relay as a fallback.
- An operator flag `webrtc.iceCredentials.forceRelay` sets
  `iceTransportPolicy: relay` in the browser for networks that must not
  leak host or server-reflexive candidates.
- Forced relay requires a backend other than `none`. The chart fails
  rendering otherwise.

### Optional TURN server in the chart: eturnal (recommended over coturn)
- **Why eturnal:**
  - Erlang/OTP, the same runtime family as the platform.
  - A small, readable YAML config.
  - A first-class TURN REST `secret`.
  - A default `blacklist` of private, loopback and link-local peer
    addresses, extendable with cluster CIDRs.
  - An official multi-arch container image.
- **Why not coturn:** it is more widely deployed but larger, C-based, with
  a longer CVE history, and it needs explicit `denied-peer-ip` lines to
  avoid becoming an open relay into the cluster.
- **What the chart renders** (`turnServer.enabled`, default `false`):
  - A Deployment (1 replica by default; the TURN REST scheme is stateless,
    so more replicas behind the Service are fine).
  - A Service of type `LoadBalancer` (default) or `NodePort`, exposing UDP
    and TCP 3478, optional TLS 5349 (cert from cert-manager `Certificate`
    or an existing TLS Secret), and a bounded relay range (default
    49160-49200, at most 1000 ports).
  - `externalAddress` (required when enabled) is advertised as the relay
    address.
  - A ConfigMap.
  - A NetworkPolicy permitting ingress on those ports.
- **Peer deny list:** the server denies relaying to RFC 1918, loopback,
  link-local, CGNAT (100.64.0.0/10), ULA, and the configured pod and
  service CIDRs. The single exception is that core-elx pod traffic may
  reach the relay ports from inside the cluster (an allow for the release's
  core pod selector on the TURN NetworkPolicy, not a peer allow).
- **ICE list:** when the chart TURN server is enabled with
  `static_secret`, the chart adds its `turn:`/`turns:` URLs (external
  address) to the browser ICE list. The core-elx peer gets the in-cluster
  Service URL.

### NetworkPolicy implications
- **Core-elx egress** reuses RDP's optional additive egress policy shape:
  explicit CIDRs and ports, core-only.
- **Generalized key:** that policy moves under
  `webrtc.networkPolicy`, and the RDP keys alias to it, so the camera relay
  gets the same opt-in egress to the TURN server or Cloudflare TURN ranges.
- **Cloudflare API:** the API call goes through Smokescreen, so the egress
  ACL needs `rtc.live.cloudflare.com`. That is documented, not chart
  managed.

### Failure behavior
- If the provider cannot mint (secret file missing at runtime, Cloudflare
  timeout or non-2xx, egress denied), the signaling response returns the
  STUN-only list and `ice_credentials: "unavailable"`.
- The viewer still attempts WebRTC and then falls back to the websocket
  transports per the existing camera-streaming requirement.
- Each failure:
  - emits telemetry;
  - logs a warning naming the backend and reason class, never the secret
    or token;
  - updates a per-deployment ICE health indicator visible in the camera
    relay and remote desktop settings.
- **Startup checks:**
  - Static config errors (malformed ICE URLs, TTL out of range, TURN URLs
    without a secret source) fail at Helm render and again at release
    runtime config load. This matches RDP's current behavior.
  - Cloudflare reachability is not checked at boot.

### Rate limiting
- Minting is limited per actor (default 30/min) and per session (default
  6/min) in each process.
- Excess requests get the STUN-only list plus a rate-limited status. This
  bounds Cloudflare API usage and how much credential material any one
  viewer can collect.

### Observability
Telemetry events:
- `[:serviceradar, :webrtc, :ice_credentials, :mint]`, with backend, result
  and duration.
- `[:serviceradar, :webrtc, :ice_candidate_pair, :selected]`, with
  candidate type (host, srflx or relay) and feature, from core-elx's
  ExWebRTC peer stats.

These feed existing metrics through JetStream per the telemetry rule.

## Risks / Trade-offs
- **A TURN server exposed on the public internet is an abuse target.**
  Mitigations: HMAC credentials with short TTLs, the peer deny list,
  relay-port bounds, and optional `max-allocations`/bandwidth limits in
  eturnal's config.
- **Cloudflare dependence.** Mitigation: fail-soft to STUN plus the
  websocket fallback, and a health indicator.
- **Hairpin routing for the core peer.** Mitigation: the core peer uses the
  in-cluster Service URL, and the relay fallback is on both sides.
- **The RDP migration could regress RDP.** Mitigation: the move keeps RDP's
  existing tests and values keys, and the provider's `static_secret`
  backend must produce byte-identical credentials for the same inputs.

## Migration Plan
1. Add the provider and the `static_secret` backend, and move RDP onto it
   with its tests unchanged.
2. Wire the camera relay (web-ng signaling plus the core-elx peer). The
   default backend `none` keeps today's STUN-only behavior.
3. Add the `cloudflare` backend.
4. Add the optional eturnal chart component and its validation.
5. Enable on demo: choose a backend, create the Secret, open the TURN ports
   (self-hosted) or add `rtc.live.cloudflare.com` to the egress ACL
   (Cloudflare).

Rollback: set the backend to `none`. Viewers return to STUN-only plus the
websocket fallback.

## Open Questions
- Demo backend choice and public exposure: which external address and
  ports can the demo load balancer or firewall expose for a self-hosted
  TURN server? Or should demo start on Cloudflare?
- Should `forceRelay` default to `true` for remote desktop, which carries
  more sensitive content than camera tiles?
- Do we need TLS 5349 (TURNS over 443-style egress) on demo, or are UDP and
  TCP 3478 enough for the expected viewer networks?
