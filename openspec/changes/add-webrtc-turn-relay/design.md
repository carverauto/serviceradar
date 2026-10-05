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
- All metrics flow through NATS JetStream and are persisted by EventWriter
  (StarRocks when enabled, otherwise CNPG); nothing writes telemetry rows
  directly.

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
- **`cloudflare`** (bring your own Cloudflare account):
  - Per viewer, call
    `POST https://rtc.live.cloudflare.com/v1/turn/keys/<turn_key_id>/credentials/generate-ice-servers`
    with the provisioned TURN key's secret as the bearer token and
    `{"ttl": <seconds>}`, through `EgressClient`, so the Smokescreen proxy
    applies.
  - The response's `iceServers` (with username and credential) is passed
    through after URL-scheme validation.
  - The TURN key ID and key secret come from the provisioning flow below and
    are read from the unified credential store, never from Helm values or a
    mounted file.
  - TTL default 600s, bounded as above. Request timeout 5s. No caching across
    viewers: credentials are per viewer.
- **Selection:** the active backend lives in the deployment's
  **WebRTC relay settings** record (`none|static_secret|cloudflare`, default
  `none`), edited in Settings. Helm still owns everything that is
  infrastructure: the `static_secret` shared-secret Secret and the optional
  TURN server. STUN URLs from the static ICE list are always appended.

### Which secrets go where
- **TURN REST shared secret (`static_secret`, chart TURN server): an
  infrastructure secret.** It authenticates ServiceRadar to its own
  media-relay server, the same class as NATS creds and session keys. It has
  one consumer, is never scoped to a target, and stays an operator-owned
  Kubernetes Secret (or OpenBao-synced Secret) mounted into web-ng, core-elx
  and the TURN server only. It is not stored in
  `platform.network_credential_secrets`.
- **Cloudflare API token and the provisioned TURN key secret: integration
  credentials.** They authenticate ServiceRadar to a third-party service the
  operator brings, and operators enter and rotate them in the product. Per the
  repository credential rule they are stored encrypted in
  `platform.network_credential_secrets` and managed in the canonical
  credentials settings area, under a new native descriptor `cloudflare` with
  auth method `api_token` and purposes `turn_provisioning` (the account API
  token) and `turn_key` (the provisioned key secret, created by the system).
  The descriptor keeps `supports_rules: true`; it is not hidden from the rule
  form. See "Credential binding" for why the TURN settings reference them
  directly.

### Credential binding: direct reference, not credential rules
The WebRTC relay settings record is a deployment-level singleton, like
`ServiceRadar.Integrations.OutboundMailSettings`. Credential rules select
material dynamically for a target query or compiler; here there is no target
and exactly one consumer, so a rule would add an indirection with nothing to
select. The settings record therefore references both secrets directly, and
meets every condition the credential rule sets for a direct reference:
- **Product contract:** this change (Settings -> Media relay (TURN)).
- **Restrictive foreign keys:** `cloudflare_api_token_secret_id` and
  `cloudflare_turn_key_secret_id` reference `network_credential_secrets` with
  `on_delete: :restrict`, as `outbound_mail_settings` does.
- **Usage inventory:** `ServiceRadar.Credentials.CredentialUsage` gains a
  `webrtc_relay_settings` direct-consumer source with a label like
  "Media relay (TURN), Cloudflare API token" and "... TURN key".
- **Guarded deletion:** `GuardCredentialDestroy` refuses to delete either
  secret while the settings reference it; the restrictive FK backs it up.
- **Navigable usage surface:** the credential's usage view links to
  Settings -> Media relay (TURN), and that page links back to the credential.

### No chart-mounted Cloudflare token
GitOps installs do **not** get a Helm value for the Cloudflare token. Two live
sources (a mounted Secret and the credential store) would disagree after the
first rotation in the UI. Automation uses the existing authenticated API
instead: create the credential with `POST /network-credential-secrets`, then
set the relay settings (backend, credential reference) and trigger
provisioning through the settings API. The credential store is the single
source of truth.

### Settings UI and Cloudflare provisioning
A web-ng page **Settings -> Media relay (TURN)** (route `/settings/webrtc`,
registered in the settings catalog under the system category), gated by a new
RBAC permission `settings.webrtc.manage` in the core permission catalog.
Read-only status is visible with `settings.webrtc.view`.
- **Backend:** none / Cloudflare / self-hosted (`static_secret`). Self-hosted
  is selectable only when the chart mounted the shared secret; the page says
  so otherwise.
- **Cloudflare:** pick an existing `cloudflare` credential or create one
  inline (it lands in the credential store, not on the settings record). The
  token needs Cloudflare Realtime (Calls) edit permission on the account, plus
  account analytics read for the usage dashboard. The page names both.
- **Provision:** core resolves the account ID from the token, then calls
  `POST https://api.cloudflare.com/client/v4/accounts/<account_id>/calls/turn_keys`
  through `EgressClient`. The returned key ID is stored on the settings
  record; the returned key secret is stored as a system-created
  `cloudflare`/`turn_key` credential and referenced directly.
- **Idempotency:** provisioning runs as an Oban job unique per settings record
  with a provisioning-attempt id. Each created key carries a name derived from
  the deployment id and attempt id, so a retried attempt finds its own key by
  name instead of creating a second one.
- **Partial failure:** if Cloudflare created the key but storing the secret
  or updating the settings fails, the job deletes that key
  (`DELETE .../calls/turn_keys/<key_id>`) before reporting failure. If the
  delete also fails, the attempt is recorded as `orphaned_key` with the key ID
  (never the secret) and a cleanup job retries the delete with backoff.
- **Status:** `not_configured`, `provisioning`, `provisioned`, `failed` with a
  reason class (`unauthorized`, `forbidden`, `rate_limited`, `egress_denied`,
  `timeout`, `upstream_error`), plus last success and key ID suffix.
- **Rotate:** create a new key, store its secret, switch the settings to it,
  then delete the old key and its credential. Viewers already holding
  credentials from the old key keep them until their TTL ends.
- **Revoke:** delete the key on Cloudflare, delete the system-created key
  credential, and set the backend to `none` (the operator's API token
  credential is left for the operator to delete).
- **Egress:** the Smokescreen ACL needs `api.cloudflare.com` (provisioning and
  analytics) and `rtc.live.cloudflare.com` (per-viewer minting).

### Usage telemetry and dashboard
All usage data rides JetStream and is persisted by EventWriter's existing
`METRICS` stream (`metrics.>`) as generic timeseries metrics, the same shape
the plugin metrics publisher uses under `metrics.timeseries`, so it lands in
the timeseries metrics store (StarRocks when enabled, otherwise CNPG) and is
SRQL-queryable. No new table.
- **Our own telemetry** on `metrics.timeseries.webrtc.*`:
  - `webrtc_ice_mints_total` (labels: feature, backend, result, reason class);
  - `webrtc_ice_mint_duration_ms`;
  - `webrtc_viewer_connections_total` (labels: feature, candidate type
    `host|srflx|relay|failed`).
  web-ng publishes mint metrics (it mints for browsers); core-elx publishes
  mint and candidate-pair metrics for its peers.
- **Cloudflare usage poller:** an Oban cron job in core (every 15 minutes,
  `:integrations` queue) queries the Cloudflare GraphQL Analytics API TURN
  usage dataset for the provisioned key over the last window and publishes
  `webrtc_turn_ingress_bytes`, `webrtc_turn_egress_bytes` and
  `webrtc_turn_concurrent_connections` samples to
  `metrics.timeseries.webrtc.cloudflare`. Exact dataset and field names are
  confirmed against Cloudflare's schema at implementation. A poll failure is a
  telemetry event, not a provisioning-status change.
- **NATS permissions:** core's and web-ng's NATS identities do not publish on
  `metrics.>` today. The chart grants each exactly
  `metrics.timeseries.webrtc.>` (both auth modes: cert-mapped users and the
  compose operator/JWT users). Missing grants show up as broker Permissions
  Violations, so the chart unittest asserts them.
- **Dashboard:** the Media relay (TURN) settings page shows an SRQL-backed
  usage panel: relay share of viewer connections (relay / all successful),
  mint failures by reason, and for Cloudflare bytes relayed per day with a
  30-day trend. An operator-set monthly relay-bytes threshold raises an
  alert through the existing alerting path when crossed.
- **Control plane:** carverauto/serviceradar-control#156 surfaces the same
  setup and usage in the tenant console; this change provides the instance
  side (settings API and metrics) it builds on.

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
  - Client-facing exposure (`turnServer.exposure`):
    - `gateway` (default when Gateway API is enabled): listeners and routes on
      the shared Envoy Gateway -- UDPRoute and TCPRoute for 3478 and a
      passthrough TLSRoute for 5349. eturnal terminates TLS itself with a
      cert-manager `Certificate` (or an existing TLS Secret) for the TURN
      hostname.
    - `service`: a `LoadBalancer` or `NodePort` Service on the same ports, for
      installations without Gateway API.
  - `externalHostname` (required when enabled) is the name browsers dial in
    the `turn:`/`turns:` URLs.
  - A bounded relay port range (default 49160-49200, at most 1000 ports) that
    is reachable only in-cluster. The far end of every relayed connection is
    core-elx's WebRTC peer, so eturnal advertises its pod address as the relay
    address and the range is never published.
  - A ConfigMap.
  - A NetworkPolicy: client ports from the gateway (or the Service), relay
    ports only from core-elx pods.
- **Peer policy:** the server denies relaying to RFC 1918, loopback,
  link-local, CGNAT (100.64.0.0/10), ULA, and the configured pod and service
  CIDRs, with two explicit allows: the server's own relay addresses (so a
  browser relay and a core-elx relay on the same server can reach each other)
  and the release's core-elx pod addresses. Everything else in-cluster stays
  denied.
- **Behind the gateway:** eturnal sees Envoy's address as each client's
  transport address. TURN allocations are keyed per 5-tuple, so this is
  fine; server-reflexive candidates still come from the public STUN entry.
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
- **Cloudflare API:** provisioning, analytics and minting go through
  Smokescreen, so the egress ACL needs `api.cloudflare.com` and
  `rtc.live.cloudflare.com`. That is documented, not chart managed.

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
3. Add the `cloudflare` descriptor, the WebRTC relay settings record (with
   its credential-usage and guarded-deletion wiring), the provisioning job,
   the Settings page and the `cloudflare` backend.
3a. Add the usage telemetry, the NATS grants, the Cloudflare usage poller and
   the dashboard panel.
4. Add the optional eturnal chart component and its validation.
5. Enable on demo: create the shared-secret Secret and expose the TURN
   listeners (self-hosted); add `api.cloudflare.com` and
   `rtc.live.cloudflare.com` to the egress ACL, enter the Cloudflare API token
   in Settings and provision (Cloudflare).

Rollback: set the backend to `none`. Viewers return to STUN-only plus the
websocket fallback.

## Resolved Questions
Decided by the maintainer on 2026-10-03:
- Demo exercises BOTH backends: the self-hosted eturnal component and the
  `cloudflare` backend (selectable per environment; demo validates each).
- Self-hosted exposure uses the existing shared Envoy Gateway
  (`serviceradar-shared-gateway`), not a dedicated LoadBalancer. It already
  carries demo UDPRoute (syslog) and TLSRoute (OTLP) listeners. The chart adds
  listeners/routes for UDP 3478 (UDPRoute), TCP 3478 (TCPRoute) and TLS 5349
  (TLSRoute, passthrough; eturnal terminates TLS with a cert-manager
  certificate for the TURN hostname).
- The relay port range is NOT exposed publicly. Every relayed connection's
  far end is core's in-cluster ex_webrtc peer, so eturnal advertises its pod
  address as the relay address and only in-cluster traffic reaches the relay
  ports. A NetworkPolicy limits relay-port ingress to core pods.
- Behind the gateway, eturnal sees Envoy's address as the client transport
  address. That is acceptable for TURN allocations (keyed per 5-tuple); STUN
  server-reflexive candidates keep coming from the public STUN entry, not from
  eturnal.
- TLS 5349 is enabled on demo so TURNS is tested alongside UDP/TCP 3478.
- `forceRelay` defaults to `false` for camera relay and remote desktop; relay
  candidates are a fallback an operator can force per feature once a backend
  is configured.
- Cloudflare is bring-your-own: the operator enters an API token in Settings
  and ServiceRadar provisions the TURN key (amended 2026-10-03; supersedes the
  earlier "infrastructure Secret" decision for the Cloudflare token). The token
  and key secret are integration credentials in the unified credential store.
- A usage dashboard ships with the feature; the SaaS tenant console
  counterpart is carverauto/serviceradar-control#156.
