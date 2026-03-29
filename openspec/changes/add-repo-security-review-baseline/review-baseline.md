# Repository Security Review Baseline

## Status
- Review artifact version: `2026-03-29-k8s-demo-pass-1`
- Proposal: `add-repo-security-review-baseline`
- Review mode: primary-scope first, trust-boundary driven
- Canonical disposition rule:
  - `covered-by-change` means an existing OpenSpec hardening change already owns remediation.
  - `accepted-risk` means the issue is intentionally not being remediated and must include rationale.
  - `new-change-required` means a dedicated follow-up change still needs to be opened.

## Trust Boundary Inventory

| Trust Boundary | Primary Directories | Secondary Directories | Review Focus |
| --- | --- | --- | --- |
| Authentication and session binding | `elixir/web-ng/lib`, `elixir/serviceradar_core/lib`, `elixir/serviceradar_core_elx/lib` | `go/pkg/spireadmin`, `tls`, `docker/compose` | login flows, token type restrictions, callback/session state, password reset, gateway/proxy auth |
| Authorization and admin/API control | `elixir/web-ng/lib`, `elixir/serviceradar_core/lib` | `k8s/argocd`, `k8s/demo` | RBAC checks, route protection, admin action scoping, cross-resource atomicity |
| Onboarding and bootstrap | `go/pkg/edgeonboarding`, `rust/edge-onboarding`, `go/pkg/config/bootstrap`, `rust/config-bootstrap`, `elixir/web-ng/lib`, `elixir/serviceradar_core/lib` | `tls`, `docker/compose` | token integrity, certificate distribution, bootstrap URL trust, script/config generation |
| Artifact and external fetch handling | `elixir/web-ng/lib`, `elixir/serviceradar_core/lib`, `go/pkg/agent` | `go/pkg/datasvc`, `go/pkg/nats`, `helm/serviceradar` | SSRF, redirect handling, streaming bounds, credential leakage, trusted source enforcement |
| Agent runtime, plugin execution, self-update | `go/pkg/agent`, `elixir/web-ng/lib`, `elixir/serviceradar_core/lib`, `elixir/serviceradar_agent_gateway/lib` | `go/cmd/wasm-plugins`, `rust/log-collector`, `rust/flowgger`, `rust/trapd` | plugin delivery, release rollout, runtime config injection, authenticated download paths |
| Deployment and network exposure | `helm/serviceradar`, `elixir/serviceradar_agent_gateway/lib`, `elixir/serviceradar_core/lib` | `k8s/demo`, `k8s/sr-testing`, `k8s/external-dns`, `tls` | service exposure, network policy, internal port publication, certificate/bootstrap secrets |

## Scope Coverage Matrix

### Primary Scope

| Directory | Tier | Status | Evidence / Notes |
| --- | --- | --- | --- |
| `elixir/web-ng/lib` | Primary | reviewed | Extensive auth, onboarding, plugin/package, admin API, bundle-delivery findings already mapped to hardening changes. |
| `elixir/serviceradar_core/lib` | Primary | reviewed | Release artifact delivery, onboarding, identity/accounting, edge bundle/script generation reviewed and mapped. |
| `elixir/serviceradar_agent_gateway/lib` | Primary | reviewed | Release artifact authorization, gateway startup TLS, cert issuance, and camera relay ownership paths reviewed and mapped to a dedicated hardening change. |
| `elixir/serviceradar_core_elx/lib` | Primary | reviewed | Camera ingress transport/auth, analysis-worker outbound HTTP dispatch, and boombox relay temp-file handling reviewed. Remaining issues are recorded below. |
| `go/pkg/agent` | Primary | reviewed | Release-update trust boundaries, plugin/runtime network surfaces, control stream, and sync-runtime outbound paths reviewed. Cross-origin release redirect trust gap recorded below. |
| `go/pkg/edgeonboarding` | Primary | reviewed | Signed tokens, HTTPS enforcement, env override handling, collector onboarding reviewed and mapped. |
| `go/pkg/grpc` | Primary | reviewed | Security provider defaults, SPIFFE identity binding, and insecure transport fallback reviewed. New gRPC package findings recorded. |
| `go/pkg/config/bootstrap` | Primary | reviewed | Core bootstrap-to-core template registration path reviewed; insecure transport fallback finding recorded and mapped to a dedicated hardening change. |
| `rust/edge-onboarding` | Primary | reviewed | Rust onboarding token parsing and package download transport reviewed; fail-open token/transport findings recorded and mapped to a dedicated hardening change. |
| `rust/config-bootstrap` | Primary | reviewed | File-only config loader reviewed. No network, token, transport, or shell trust-boundary issues identified in the current implementation. |
| `helm/serviceradar` | Primary | reviewed | Gateway exposure reviewed as intentional. Shared onboarding-key and cluster-cookie defaults are fixed. Remaining Helm/SPIRE deployment-surface findings are recorded below. |

### Secondary Scope

| Directory | Tier | Status | Notes |
| --- | --- | --- | --- |
| `go/pkg/datasvc` | Secondary | reviewed | Datasvc gRPC upload/object-store bounds reviewed. Object upload/storage exhaustion finding recorded below. |
| `go/pkg/nats` | Secondary | reviewed | NATS account/JWT signing helpers reviewed. Isolation-bypass and unbounded JetStream-quota findings recorded below. |
| `go/pkg/spireadmin` | Secondary | reviewed | Reviewed package surface and repo callers. No live constructor/call path found in the current tree, so no confirmed exploitable finding was recorded. |
| `go/pkg/trivysidecar` | Secondary | reviewed | Reviewed runtime, publisher, and deployment wiring. Shipped manifests use TLS + NATS creds; no new confirmed exploitable finding recorded in the current tree. |
| `go/pkg/scan` | Secondary | reviewed | Reviewed ICMP/TCP/SYN scanner paths and caller wiring. No new confirmed exploitable finding recorded in the current tree. |
| `go/cmd/wasm-plugins` | Secondary | reviewed | Reviewed shipped AXIS, UniFi Protect, and dusk WASM plugin packages. AXIS websocket credential handling finding recorded below. |
| `rust/trapd` | Secondary | reviewed | Reviewed SNMP ingest, NATS publish, and optional gRPC status server paths. A fail-open gRPC transport finding is recorded below. |
| `rust/log-collector` | Secondary | reviewed | Reviewed startup, config-bootstrap, OTEL delegation, and shipped config samples. No new confirmed exploitable finding recorded in the current tree. |
| `rust/consumers/zen` | Secondary | reviewed | Reviewed NATS, decision-engine, and optional gRPC status server paths. A fail-open gRPC transport and default exposure finding is recorded below. |
| `rust/flowgger` | Secondary | reviewed | Reviewed gRPC sidecar, input listeners, and NATS output transport wiring. A fail-open gRPC transport finding is recorded below. |
| `rust/srql` | Secondary | reviewed | Reviewed parser, query engine, and HTTP API auth path. A fail-open API authentication finding is recorded below. |
| `docker/compose` | Secondary | reviewed | Reviewed compose runtime defaults, shipped secret material, NATS exposure, and SPIRE bootstrap scripts. Static secret defaults, public monitoring exposure, and unverified runtime binary downloads are recorded below. |
| `k8s/demo` | Secondary | reviewed | Reviewed default base and prod/staging overlays. Default base still mounts host SPIRE sockets into workloads even though SPIRE is optional, and overlays publish datasvc externally by default. |
| `k8s/sr-testing` | Secondary | not-started | Pending after primary scope closure. |
| `k8s/external-dns` | Secondary | not-started | Pending after primary scope closure. |
| `k8s/argocd` | Secondary | not-started | Pending after primary scope closure. |
| `tls` | Secondary | not-started | Pending after primary scope closure. |

## Findings Output Format

Each finding entry in this artifact SHALL include:
- `Finding ID`
- `Severity`
- `Exploitability / Preconditions`
- `Affected Paths`
- `Impact`
- `Remediation Guidance`
- `Disposition`

Disposition values used in this artifact:
- `covered-by-change`
- `accepted-risk`
- `new-change-required`

## Findings Ledger

| ID | Severity | Affected Paths | Summary | Disposition |
| --- | --- | --- | --- | --- |
| `SR-001` | High | `elixir/web-ng/lib`, `go/pkg/edgeonboarding`, `go/pkg/cli` | Edge onboarding accepted unsigned / tamperable tokens and allowed insecure bootstrap URL trust. | `covered-by-change: harden-edge-onboarding-enrollment` |
| `SR-002` | High | `elixir/web-ng/lib`, `go/pkg/edgeonboarding`, `elixir/serviceradar_core/lib`, `elixir/serviceradar_agent_gateway/lib` | Collector onboarding and gateway-served artifact delivery were not bound tightly enough to authenticated identity. | `covered-by-change: harden-collector-onboarding-and-release-artifact-authorization` |
| `SR-003` | High | `elixir/web-ng/lib`, `elixir/serviceradar_core/lib` | Release import and bundle delivery trusted generic external hosts, query-string bearer tokens, and unsafe outbound fetch paths. | `covered-by-change: harden-release-import-and-bundle-delivery` |
| `SR-004` | High | `elixir/web-ng/lib`, `go/pkg/agent`, `elixir/serviceradar_core/lib` | Legacy collector URL tokens and plugin bearer URLs leaked secrets through URLs and generated config. | `covered-by-change: remove-legacy-collector-url-tokens-and-harden-plugin-blob-delivery` |
| `SR-005` | High | `elixir/web-ng/lib` | POST endpoints still accepted query-param token fallbacks and bootstrap commands used request-derived base URLs. | `covered-by-change: remove-post-query-token-fallbacks-and-pin-bundle-base-url` |
| `SR-006` | High | `elixir/web-ng/lib` | Admin bootstrap flows minted security-sensitive commands/tokens from request host data. | `covered-by-change: pin-admin-bootstrap-urls-to-configured-endpoints` |
| `SR-007` | High | `elixir/web-ng/lib`, `elixir/serviceradar_core/lib` | OIDC/SAML metadata and observability fetches had outbound validation gaps; auth callbacks and TLS verification had fail-open behavior. | `covered-by-change: harden-auth-and-observability-outbound-fetches`, `harden-auth-redirect-targets-and-observability-secret-handling`, `harden-auth-session-binding-and-cli-tls-verification`, `harden-auth-metadata-fetch-and-refresh-rotation`, `harden-token-pipelines-and-federated-assertion-validation` |
| `SR-008` | High | `elixir/web-ng/lib` | Bootstrap scripts, SSO provisioning, topology snapshots, and bundle error responses exposed command injection, privilege, or information-disclosure risk. | `covered-by-change: harden-bootstrap-scripts-and-sensitive-endpoints` |
| `SR-009` | Medium | `elixir/web-ng/lib`, `elixir/serviceradar_core/lib` | Bundle tempfiles, client IP trust, token revocation durability, and GitHub signer trust had hardening gaps. | `covered-by-change: harden-bundle-tempfiles-and-auth-trust-boundaries` |
| `SR-010` | High | `elixir/web-ng/lib` | Admin API path handling and sequential user updates allowed path confusion, inconsistent user state, and silent permission retention. | `covered-by-change: harden-admin-api-transport-and-user-update-atomicity` |
| `SR-011` | High | `elixir/web-ng/lib`, `elixir/serviceradar_core/lib` | Plugin upload/import authenticity checks were incomplete and remote fetches could be abused for memory exhaustion or private repo confusion. | `covered-by-change: harden-plugin-import-authenticity-and-fetch-bounds` |
| `SR-012` | Medium | `elixir/serviceradar_core/lib` | Identity cache eviction, credential use counters, and first-user bootstrap had denial-of-service or race-condition weaknesses. | `covered-by-change: harden-identity-cache-and-credential-accounting` |
| `SR-013` | High | `elixir/serviceradar_core/lib` | Release artifact mirroring followed redirects implicitly, buffered downloads unsafely, and edge-site setup scripts interpolated shell-sensitive names. | `covered-by-change: harden-edge-artifact-fetch-and-leaf-bundles` |
| `SR-014` | High | `elixir/serviceradar_agent_gateway/lib` | Agent gateway still has a fail-open plaintext listener mode, camera relay session operations are not bound to the owning agent, and cert issuance uses predictable temp paths. | `covered-by-change: harden-agent-gateway-edge-identity-boundaries` |
| `SR-015` | High | `elixir/serviceradar_core_elx/lib`, `elixir/web-ng/lib`, `elixir/serviceradar_core/lib` | Core-ELX camera ingress still fails open on transport identity, and analysis-worker HTTP dispatch/probe paths trust operator-supplied URLs without outbound fetch policy enforcement. | `covered-by-change: harden-core-elx-camera-ingress-and-analysis-fetch` |
| `SR-016` | High | `go/pkg/grpc` | The shared Go gRPC package still fails open to insecure transport when security config is absent and allows overly-broad SPIFFE identity authorization when server identity is omitted. | `covered-by-change: harden-go-grpc-security-defaults-and-spiffe-identity-binding` |
| `SR-017` | High | `go/pkg/config/bootstrap` | Bootstrap template registration still falls back to plaintext gRPC when `CORE_SEC_MODE` is empty or `none`, allowing fail-open core transport during bootstrap/config registration. | `covered-by-change: harden-bootstrap-core-transport-defaults` |
| `SR-018` | High | `rust/edge-onboarding` | Rust edge onboarding still accepts legacy/unsigned token forms, permits host override to replace the token API URL, and defaults bare hosts to plaintext HTTP for package download. | `covered-by-change: harden-rust-edge-onboarding-token-and-transport-trust` |
| `SR-019` | High | `helm/serviceradar` | Helm defaults still ship a fixed onboarding signing key and a fixed Erlang cluster cookie, creating shared-secret reuse across installs unless operators override them manually. | `covered-by-change: harden-helm-generated-secret-defaults` |
| `SR-020` | High | `helm/serviceradar` | The Helm chart exposes the SPIRE server via a `LoadBalancer` by default and disables kubelet verification in the SPIRE agent workload attestor, weakening the identity plane when SPIRE mode is enabled. | `covered-by-change: harden-helm-spire-exposure-and-attestation-defaults` |
| `SR-021` | High | `go/pkg/agent` | Agent self-update follows cross-origin HTTPS redirects, allowing authenticated or signed artifact downloads to leave the original trust boundary. | `covered-by-change: harden-agent-release-download-redirect-trust` |
| `SR-022` | Medium | `elixir/serviceradar_core_elx/lib` | Core-ELX boombox capture helpers still write relay-derived media samples to predictable temp paths under the global temp directory. | `covered-by-change: harden-core-elx-boombox-tempfile-handling` |
| `SR-023` | Medium | `go/pkg/datasvc` | Datasvc object uploads are not bounded end-to-end and the JetStream object bucket is created without a storage cap, allowing authenticated writers to exhaust backing storage. | `covered-by-change: harden-datasvc-object-upload-bounds` |
| `SR-024` | High | `go/pkg/nats`, `go/pkg/datasvc` | The NATS account-signing layer accepted foreign imports, namespace-escaping exports/mappings, and reserved control-subject permission overrides without guardrails, allowing authorized callers to widen authority beyond the intended account scope. | `covered-by-change: harden-nats-account-scope-guardrails` |
| `SR-025` | Medium | `go/pkg/nats`, `go/pkg/datasvc` | New NATS accounts received unlimited JetStream quotas by default when explicit limits were omitted, enabling storage and consumer exhaustion by provisioned accounts. | `covered-by-change: harden-nats-account-scope-guardrails` |
| `SR-026` | Medium | `go/cmd/wasm-plugins/axis`, `go/pkg/agent` | The shipped AXIS camera plugin embeds camera credentials in the VAPIX event websocket URL userinfo even though the agent runtime supports structured websocket headers, creating avoidable credential leakage risk through URL-bearing surfaces. | `covered-by-change: harden-axis-plugin-websocket-credential-handling` |
| `SR-027` | High | `rust/trapd` | The optional trapd gRPC status server explicitly permits plaintext mode and starts without TLS when `grpc_security.mode` is `none`, weakening an internal service trust boundary. | `covered-by-change: harden-rust-trapd-grpc-transport-defaults` |
| `SR-028` | High | `rust/consumers/zen` | Zen starts a gRPC status server on `0.0.0.0:50055` by default and serves plaintext whenever `grpc_security` is absent or `none`, exposing an internal service boundary without authenticated transport. | `covered-by-change: harden-rust-zen-grpc-transport-defaults` |
| `SR-029` | High | `rust/flowgger` | Flowgger’s optional gRPC health sidecar accepts `grpc.mode = "none"` and silently downgrades incomplete `mtls` config to plaintext serving, weakening an internal service boundary. | `covered-by-change: harden-rust-flowgger-grpc-transport-defaults` |
| `SR-030` | High | `rust/srql` | SRQL disables API key enforcement entirely when no env or KV-backed key is configured, leaving `/api/query` and `/translate` unauthenticated on the normal listener. | `covered-by-change: harden-rust-srql-api-auth-defaults` |
| `SR-031` | High | `docker-compose.yml`, `docker/compose` | The main Docker Compose stack still ships static default secret material for Erlang distribution, Phoenix session signing, and plugin download signing, allowing cross-install trust reuse when operators do not override those env vars. | `covered-by-change: harden-docker-compose-secret-defaults-and-bootstrap-integrity` |
| `SR-032` | Medium | `docker-compose.yml`, `docker/compose/nats.docker.conf` | The main Docker Compose stack publishes the unauthenticated NATS monitoring endpoint on host port `8222` by default, exposing broker metadata and runtime state outside the internal compose network. | `covered-by-change: harden-docker-compose-secret-defaults-and-bootstrap-integrity` |
| `SR-033` | High | `docker/compose/spire` | SPIRE bootstrap and agent startup scripts download and execute SPIRE binaries at runtime without checksum or signature verification, creating a supply-chain trust gap in the compose bootstrap path. | `covered-by-change: harden-docker-compose-secret-defaults-and-bootstrap-integrity` |
| `SR-034` | High | `k8s/demo/base` | The default demo base mounts `/run/spire/sockets` from the host into multiple workloads using `hostPath` even though SPIRE is documented as optional and outside the default install path. | `covered-by-change: harden-demo-k8s-control-plane-exposure-and-spire-mounts` |
| `SR-035` | High | `k8s/demo/prod`, `k8s/demo/staging` | The prod and staging demo overlays publish datasvc gRPC through `LoadBalancer` services by default, exposing an internal control-plane/KV service outside the cluster. | `covered-by-change: harden-demo-k8s-control-plane-exposure-and-spire-mounts` |

### Finding Details

#### `SR-001` Unsigned or tamperable onboarding/bootstrap trust
- Severity: High
- Exploitability / Preconditions: attacker can alter onboarding token or influence bootstrap transport path.
- Affected Paths:
  - `elixir/web-ng/lib`
  - `go/pkg/edgeonboarding`
  - `go/pkg/cli`
- Impact: unauthorized bootstrap source trust, token tampering, downgrade to insecure onboarding.
- Remediation Guidance: signed-only onboarding tokens, strict HTTPS verification, explicit trusted endpoint binding.
- Disposition: `covered-by-change: harden-edge-onboarding-enrollment`

#### `SR-002` Collector onboarding and release artifact identity binding gaps
- Severity: High
- Exploitability / Preconditions: attacker holds a valid enrolled workload identity or can tamper collector bootstrap tokens.
- Affected Paths:
  - `elixir/web-ng/lib`
  - `go/pkg/edgeonboarding`
  - `elixir/serviceradar_core/lib`
  - `elixir/serviceradar_agent_gateway/lib`
- Impact: artifact or collector bootstrap material may be fetched outside intended agent/collector identity.
- Remediation Guidance: signed collector tokens, identity-bound artifact authorization, signed-only parsing paths.
- Disposition: `covered-by-change: harden-collector-onboarding-and-release-artifact-authorization`

#### `SR-003` Release import and bundle-delivery outbound fetch / bearer-token leakage
- Severity: High
- Exploitability / Preconditions: attacker can control import source metadata, asset URLs, or observe operator-generated URLs.
- Affected Paths:
  - `elixir/web-ng/lib`
  - `elixir/serviceradar_core/lib`
- Impact: SSRF, credential leakage to untrusted hosts, leakage of onboarding or plugin bearer tokens through URLs/logs/history.
- Remediation Guidance: constrain import hosts, forbid query-string bearer delivery, fail closed on unsafe fetch destinations.
- Disposition: `covered-by-change: harden-release-import-and-bundle-delivery`

#### `SR-004` Legacy collector and plugin URL token leakage
- Severity: High
- Exploitability / Preconditions: attacker can observe logs, browser history, proxy logs, or copied URLs.
- Affected Paths:
  - `elixir/web-ng/lib`
  - `go/pkg/agent`
  - `elixir/serviceradar_core/lib`
- Impact: replay of bearer-style download tokens for collector or plugin artifacts.
- Remediation Guidance: remove URL token transport, require header/body token delivery, stop embedding bearer URLs in config/UI.
- Disposition: `covered-by-change: remove-legacy-collector-url-tokens-and-harden-plugin-blob-delivery`

#### `SR-005` POST query-token fallback and host-header poisoning
- Severity: High
- Exploitability / Preconditions: attacker can place bearer tokens into URLs or influence request host headers seen by admin/bootstrap flows.
- Affected Paths:
  - `elixir/web-ng/lib`
- Impact: bundle token leakage, poisoned bootstrap URLs, misdirected onboarding commands.
- Remediation Guidance: reject query-param token fallback on POST endpoints and pin bootstrap URLs to configured endpoints.
- Disposition: `covered-by-change: remove-post-query-token-fallbacks-and-pin-bundle-base-url`, `pin-admin-bootstrap-urls-to-configured-endpoints`

#### `SR-006` Metadata/auth callback/session verification weaknesses
- Severity: High
- Exploitability / Preconditions: attacker can tamper auth callbacks, discovery metadata, or exploit absent session state.
- Affected Paths:
  - `elixir/web-ng/lib`
  - `elixir/serviceradar_core/lib`
- Impact: login CSRF/session swap, redirect/phishing abuse, SSRF, insecure callback acceptance.
- Remediation Guidance: fail closed on missing session state/nonce/CSRF, validate every auth metadata endpoint and redirect target, remove TLS-skip verification paths.
- Disposition: `covered-by-change: harden-auth-and-observability-outbound-fetches`, `harden-auth-redirect-targets-and-observability-secret-handling`, `harden-auth-session-binding-and-cli-tls-verification`, `harden-auth-metadata-fetch-and-refresh-rotation`, `harden-token-pipelines-and-federated-assertion-validation`

#### `SR-007` Bootstrap script, SSO linking, and sensitive endpoint hardening gaps
- Severity: High
- Exploitability / Preconditions: attacker can influence generated shell content, exploit permissive endpoint access, or rely on implicit email-based account linking.
- Affected Paths:
  - `elixir/web-ng/lib`
- Impact: operator-side command execution, unauthorized access to sensitive topology data, account takeover through implicit SSO linking.
- Remediation Guidance: shell-safe quoting, explicit controller authorization, and removal of implicit SSO account linking.
- Disposition: `covered-by-change: harden-bootstrap-scripts-and-sensitive-endpoints`

#### `SR-008` Bundle tempfile, proxy IP trust, revocation durability, and GitHub signer trust
- Severity: Medium
- Exploitability / Preconditions: attacker can observe or precreate temporary paths, spoof forwarded headers through untrusted proxies, or rely on restart/reset conditions.
- Affected Paths:
  - `elixir/web-ng/lib`
  - `elixir/serviceradar_core/lib`
- Impact: secret leakage, IP-based policy bypass, revoked token resurrection after restart, plugin source trust confusion.
- Remediation Guidance: secure temp archive handling, trusted-proxy-aware client IP parsing, persistent revocation storage, trusted signer allowlists.
- Disposition: `covered-by-change: harden-bundle-tempfiles-and-auth-trust-boundaries`

#### `SR-009` Admin API transport and user-update atomicity
- Severity: High
- Exploitability / Preconditions: attacker or admin can supply path-segment input or partial user updates.
- Affected Paths:
  - `elixir/web-ng/lib`
- Impact: internal path confusion, partially committed role changes, failure to clear role-profile assignments.
- Remediation Guidance: encode path segments, transact multi-step admin updates, distinguish omitted from explicit null.
- Disposition: `covered-by-change: harden-admin-api-transport-and-user-update-atomicity`

#### `SR-010` Plugin import authenticity and bounded fetch hardening
- Severity: High
- Exploitability / Preconditions: attacker can submit forged upload signatures, large remote artifacts, or repositories outside trusted ownership boundaries.
- Affected Paths:
  - `elixir/web-ng/lib`
  - `elixir/serviceradar_core/lib`
- Impact: unauthenticated plugin upload acceptance, memory exhaustion, import of untrusted private content.
- Remediation Guidance: real signature verification, bounded streaming downloads, trusted owner/repository enforcement, hostile YAML/path hardening.
- Disposition: `covered-by-change: harden-plugin-import-authenticity-and-fetch-bounds`

#### `SR-011` Identity cache and credential accounting weaknesses
- Severity: Medium
- Exploitability / Preconditions: high request volume or concurrent use of shared credentials / initial registration path.
- Affected Paths:
  - `elixir/serviceradar_core/lib`
- Impact: self-inflicted cache eviction DoS, lost usage counter increments, multiple bootstrap admins during race window.
- Remediation Guidance: bounded ETS eviction scans, atomic counter updates, serialized first-user role assignment.
- Disposition: `covered-by-change: harden-identity-cache-and-credential-accounting`

#### `SR-012` Artifact redirect SSRF and leaf setup script injection
- Severity: High
- Exploitability / Preconditions: attacker can control mirrored artifact URL/redirect chain or edge-site name consumed by operator-run scripts.
- Affected Paths:
  - `elixir/serviceradar_core/lib`
- Impact: SSRF through redirect chains, memory exhaustion during artifact mirror, operator-side shell execution in NATS setup bundles.
- Remediation Guidance: manual redirect validation, streamed size-bounded fetches, safe basename fallback, shell-safe quoting of site metadata.
- Disposition: `covered-by-change: harden-edge-artifact-fetch-and-leaf-bundles`

#### `SR-014` Gateway plaintext fallback, camera relay ownership gap, and cert temp-path weakness
- Severity: High
- Exploitability / Preconditions: attacker can reach a gateway deployed with insecure fallback enabled, or an enrolled agent can obtain another relay session's identifiers, or a local attacker has filesystem access on the gateway host.
- Affected Paths:
  - `elixir/serviceradar_agent_gateway/lib`
- Impact:
  - plaintext gRPC/artifact listeners remove the mTLS trust boundary if `GATEWAY_ALLOW_INSECURE_GRPC=true`
  - camera relay heartbeat, upload, and close operations can act on any session keyed only by `relay_session_id` plus `media_ingest_id`, not the owning `agent_id`
  - predictable temp certificate work directories create local symlink/secret-handling risk around issued private keys
- Remediation Guidance:
  - remove or strongly fence insecure listener fallback from production code paths
  - bind camera relay session fetch/update/close operations to `agent_id` in addition to existing identifiers
  - replace predictable temp paths in certificate issuance with secure exclusive temp directories/files
- Disposition: `covered-by-change: harden-agent-gateway-edge-identity-boundaries`

#### `SR-023` Datasvc object upload and object-store capacity are unbounded
- Severity: Medium
- Exploitability / Preconditions: attacker or malfunctioning workload has authenticated `writer` access to datasvc and can stream arbitrary object uploads.
- Affected Paths:
  - `go/pkg/datasvc`
- Impact:
  - `UploadObject` accepts arbitrarily long client streams and forwards them directly into JetStream object storage without a cumulative service-side byte ceiling
  - datasvc applies `BucketMaxBytes` only to the KV bucket; the object store is created without `MaxBytes`, so a single writer can grow object storage until JetStream storage pressure affects other workloads
- Remediation Guidance:
  - enforce a cumulative per-object upload limit in the gRPC streaming path and fail the stream closed once the configured ceiling is exceeded
  - apply an explicit `MaxBytes` cap to the JetStream object store, either by reusing or splitting the existing bucket-cap configuration
  - add focused tests for oversize stream rejection and bounded object-store initialization
- Disposition: `covered-by-change: harden-datasvc-object-upload-bounds`

#### `SR-024` NATS account signing allows cross-namespace authority widening
- Severity: High
- Exploitability / Preconditions: an authorized caller can invoke datasvc NATS account/user signing APIs with custom imports, exports, mappings, or permissions.
- Affected Paths:
  - `go/pkg/nats`
  - `go/pkg/datasvc`
- Impact:
  - `SignAccountJWT` accepted arbitrary `StreamImport` entries and namespace-escaping export or mapping destinations without validating that the resulting JWT stayed within approved account boundaries
  - `GenerateUserCredentials` accepted reserved control-subject permission overrides, allowing callers to mint broader control-plane NATS authority than intended
  - datasvc forwarded these caller-supplied fields directly into the signing layer, so a compromised or over-privileged control-plane caller could widen NATS authority before the fix
- Remediation Guidance:
  - enforce namespace/account-bound validation on custom imports, exports, and subject-mapping destinations before signing
  - reject reserved control-subject permission overrides and preserve least-privilege defaults for user credentials
  - add focused tests proving foreign imports, escaping exports/mappings, and reserved control-subject overrides are rejected
- Disposition: `covered-by-change: harden-nats-account-scope-guardrails`

#### `SR-025` New NATS accounts default to unlimited JetStream quotas
- Severity: Medium
- Exploitability / Preconditions: a provisioned account is created without explicit JetStream limits and then publishes or provisions streams/consumers heavily.
- Affected Paths:
  - `go/pkg/nats`
  - `go/pkg/datasvc`
- Impact:
  - `ensureJetStreamEnabled` assigns `jwt.NoLimit` for memory, disk, streams, and consumers when no explicit limits are provided
  - new accounts therefore get effectively unbounded JetStream capacity by default, making storage exhaustion and noisy-neighbor conditions easier for any provisioned account
- Remediation Guidance:
  - require explicit bounded JetStream quotas or install safe finite defaults when signing new accounts
  - add tests that verify accounts no longer receive unlimited JetStream quotas by default
- Disposition: `covered-by-change: harden-nats-account-scope-guardrails`

#### `SR-026` AXIS plugin uses credential-bearing websocket URLs for camera event collection
- Severity: Medium
- Exploitability / Preconditions: an operator configures AXIS camera credentials for the shipped WASM plugin and enables event collection over the VAPIX websocket path.
- Affected Paths:
  - `go/cmd/wasm-plugins/axis`
  - `go/pkg/agent`
- Impact:
  - the AXIS plugin still builds `wss://user:pass@host/...` websocket URLs for camera event collection instead of using the structured header-bearing websocket connect path the agent runtime already supports
  - credential-bearing URLs are easier to leak through logs, traces, crash output, proxy telemetry, copied debug output, or other URL-oriented surfaces than header-based authentication
- Remediation Guidance:
  - move AXIS websocket authentication to the structured websocket connect payload with explicit headers instead of URL userinfo
  - ensure plugin result details and error surfaces do not carry credential-bearing websocket URLs
  - add focused tests proving the websocket dial payload uses headers and a credential-free URL
- Disposition: `covered-by-change: harden-axis-plugin-websocket-credential-handling`

#### `SR-027` Rust trapd gRPC status server allows plaintext transport
- Severity: High
- Exploitability / Preconditions: deployment enables `grpc_listen_addr` for trapd and leaves `grpc_security.mode` as `none`.
- Affected Paths:
  - `rust/trapd`
- Impact:
  - `trapd` requires `grpc_security` whenever the gRPC status server is enabled, but still explicitly accepts `mode = "none"` and starts the server without TLS
  - this creates a fail-open transport downgrade for an internal monitoring/control surface, which is inconsistent with the fail-closed transport contract already enforced in other gRPC packages
- Remediation Guidance:
  - reject `grpc_security.mode = "none"` for trapd whenever `grpc_listen_addr` is configured
  - require either mTLS or SPIFFE-backed authenticated transport for the trapd gRPC status server
  - add focused config and runtime tests proving trapd fails closed instead of serving plaintext
- Disposition: `covered-by-change: harden-rust-trapd-grpc-transport-defaults`

#### `SR-028` Zen gRPC status server starts plaintext by default
- Severity: High
- Exploitability / Preconditions: a deployment runs `rust/consumers/zen` with the default or sample configuration and does not provide secure `grpc_security` settings.
- Affected Paths:
  - `rust/consumers/zen`
- Impact:
  - the `zen` consumer defaults `listen_addr` to `0.0.0.0:50055` and `main.rs` always spawns the gRPC status server, so the service surface is enabled by default rather than explicit opt-in
  - `grpc_server.rs` serves plaintext whenever `grpc_security` is missing or resolves to `none`, so the default status surface crosses an internal service boundary without mTLS or SPIFFE identity
- Remediation Guidance:
  - make the gRPC status server opt-in or require authenticated transport whenever it is enabled
  - reject missing or insecure `grpc_security` for enabled gRPC serving
  - add focused tests proving the default runtime no longer exposes a plaintext gRPC port
- Disposition: `covered-by-change: harden-rust-zen-grpc-transport-defaults`

#### `SR-029` Flowgger gRPC sidecar silently downgrades to plaintext
- Severity: High
- Exploitability / Preconditions: a deployment enables the optional flowgger gRPC sidecar and either sets `grpc.mode = "none"` or configures `grpc.mode = "mtls"` without all required certificate paths.
- Affected Paths:
  - `rust/flowgger`
- Impact:
  - the flowgger gRPC helper accepts `grpc.mode = "none"` and starts a plaintext health server on the configured listener
  - even when `grpc.mode = "mtls"` is selected, missing cert material silently downgrades the server to `SecuritySettings::None` instead of failing closed
- Remediation Guidance:
  - reject `grpc.mode = "none"` for the flowgger gRPC sidecar
  - make incomplete mTLS configuration a validation error instead of a downgrade to plaintext
  - add focused tests proving the gRPC sidecar only starts under mTLS or SPIFFE-backed transport
- Disposition: `covered-by-change: harden-rust-flowgger-grpc-transport-defaults`

#### `SR-030` SRQL API authentication fails open when no key is configured
- Severity: High
- Exploitability / Preconditions: deployment starts `rust/srql` without `SRQL_API_KEY` and without a valid KV-backed key configured.
- Affected Paths:
  - `rust/srql`
- Impact:
  - SRQL logs a warning and disables API key enforcement entirely when no static or KV-backed API key is configured
  - the service still binds and serves `/api/query` and `/translate`, so query translation and query execution become unauthenticated by configuration omission
- Remediation Guidance:
  - require an API key source at startup and fail closed when none is configured
  - keep embedded/test-only construction explicit rather than allowing the standalone server to disable auth silently
  - add focused tests proving missing-key startup fails instead of serving unauthenticated query endpoints
- Disposition: `covered-by-change: harden-rust-srql-api-auth-defaults`

#### `SR-031` Docker Compose ships shared default secret material
- Severity: High
- Exploitability / Preconditions: operator deploys the main Docker Compose stack without overriding the relevant secret environment variables.
- Affected Paths:
  - `docker-compose.yml`
- Impact:
  - the compose stack templates the same default Erlang cluster cookie (`serviceradar_dev_cookie`) into core, gateway, and web-ng, so multiple installs can share distribution credentials by default
  - web-ng also receives a static `SECRET_KEY_BASE` default, enabling predictable session or token signing material reuse across installs when operators do not override it
  - core and web-ng both use the same hard-coded `PLUGIN_STORAGE_SIGNING_SECRET` default, allowing signed plugin download URLs to be forged across installations that retain the shipped value
- Remediation Guidance:
  - remove static defaults for cluster cookies, Phoenix secret material, and plugin signing secrets from the compose stack
  - generate per-install secret values during bootstrap and mount them from dedicated volumes or files
  - document explicit override behavior for operators who need deterministic values
- Disposition: `covered-by-change: harden-docker-compose-secret-defaults-and-bootstrap-integrity`

#### `SR-032` Docker Compose publishes unauthenticated NATS monitoring to the host
- Severity: Medium
- Exploitability / Preconditions: host running the main Docker Compose stack is reachable by other users or systems on the network.
- Affected Paths:
  - `docker-compose.yml`
  - `docker/compose/nats.docker.conf`
- Impact:
  - the NATS service publishes host port `8222`, and the bundled NATS config binds the HTTP monitoring endpoint to `0.0.0.0:8222`
  - that monitoring surface is not protected by the NATS mTLS client listener settings, so external callers can query broker metadata, account state, and operational telemetry that should remain internal to the compose network
- Remediation Guidance:
  - stop publishing the NATS monitoring endpoint to the host by default, or bind it to loopback only
  - keep the monitoring listener internal unless an operator explicitly opts in to external exposure for debugging
  - document any opt-in monitoring exposure as insecure by default
- Disposition: `covered-by-change: harden-docker-compose-secret-defaults-and-bootstrap-integrity`

#### `SR-033` Docker Compose SPIRE bootstrap downloads unsigned executables at runtime
- Severity: High
- Exploitability / Preconditions: compose stack uses the bundled SPIRE bootstrap path and trusts the runtime network path to GitHub or a caller-supplied download URL.
- Affected Paths:
  - `docker/compose/spire`
- Impact:
  - `bootstrap-compose-spire.sh` downloads the SPIRE server CLI tarball at runtime, extracts `spire-server`, and executes it without verifying a checksum or signature
  - `run-agent.sh` does the same for `spire-agent`
  - a compromised mirror, DNS path, or overridden download URL can therefore replace the executed bootstrap binaries before the local trust boundary is established
- Remediation Guidance:
  - stop downloading SPIRE executables during runtime bootstrap; ship pinned binaries in the image or mount vetted artifacts instead
  - if network retrieval remains unavoidable, require a pinned checksum or signature verification step before extraction and execution
  - treat download URL overrides as privileged/debug-only and document them accordingly
- Disposition: `covered-by-change: harden-docker-compose-secret-defaults-and-bootstrap-integrity`

#### `SR-034` Demo base mounts host SPIRE sockets by default even when SPIRE is optional
- Severity: High
- Exploitability / Preconditions: operator applies the default `k8s/demo/base` path on a cluster node where `/run/spire/sockets` exists or can be created on the host.
- Affected Paths:
  - `k8s/demo/base`
- Impact:
  - multiple default demo workloads mount `/run/spire/sockets` from the node filesystem using `hostPath` and point runtime config at that socket path even though the repo documents SPIFFE/SPIRE as optional and not part of the default demo install path
  - this expands the default deployment trust boundary to the node host filesystem and creates an avoidable hostPath escape surface for workloads that should otherwise run without host filesystem access
  - on clusters without the expected SPIRE socket, the manifests still create host directories and leave the workloads coupled to a host-mounted path that is not part of the advertised default install
- Remediation Guidance:
  - remove SPIRE socket `hostPath` mounts from the default demo base and gate them behind an explicit SPIRE-specific overlay
  - keep default demo workloads on file-based mTLS/runtime certs unless SPIRE is intentionally enabled
  - make any SPIRE-specific workload wiring opt-in and clearly segregated from the base install path
- Disposition: `new-change-required: harden-demo-k8s-control-plane-exposure-and-spire-mounts`

#### `SR-035` Demo overlays publish datasvc externally by default
- Severity: High
- Exploitability / Preconditions: operator applies the `prod/` or `staging/` demo overlay as shipped on a cluster with functioning `LoadBalancer` service exposure.
- Affected Paths:
  - `k8s/demo/prod`
  - `k8s/demo/staging`
- Impact:
  - both overlays include `serviceradar-datasvc-grpc-external.yaml`, which exposes datasvc gRPC as a `LoadBalancer`
  - datasvc is an internal control-plane/KV service used by platform workloads, so publishing it externally by default unnecessarily expands the attack surface of an internal administrative boundary
  - even with mTLS enabled, making the service internet- or LAN-reachable by default increases the blast radius of misissued certs, leaked client credentials, and transport parsing bugs
- Remediation Guidance:
  - remove external datasvc exposure from the default prod and staging overlays
  - require an explicit opt-in overlay or operator patch for any external datasvc access need
  - document datasvc as internal-only by default in the demo deployment materials
- Disposition: `new-change-required: harden-demo-k8s-control-plane-exposure-and-spire-mounts`

#### `SR-015` Core-ELX media ingress trust-boundary and analysis-worker SSRF gap
- Severity: High
- Exploitability / Preconditions: attacker can reach a core-elx media gRPC listener deployed without valid certs, or a privileged operator / compromised control-plane path can register or select an analysis worker endpoint that targets an internal service.
- Affected Paths:
  - `elixir/serviceradar_core_elx/lib`
  - `elixir/web-ng/lib`
  - `elixir/serviceradar_core/lib`
- Impact:
  - the core-elx camera ingress gRPC service can start without TLS when certs are absent and, when TLS is present, does not require client certificates, weakening the agent-gateway-to-core trust boundary
  - camera analysis worker dispatch and health probing issue raw HTTP requests to `endpoint_url` / `health_endpoint_url` values with no public-host validation or DNS-rebinding-safe resolution, creating an SSRF path from worker configuration into internal services
- Remediation Guidance:
  - require mTLS for the core-elx edge-facing media ingress service and fail closed when server/client trust material is absent
  - apply the existing outbound fetch policy pattern to analysis-worker HTTP delivery and health probing, including address validation and connection binding to the validated target
  - constrain worker endpoint configuration to validated safe URLs before persistence when possible
- Disposition: `covered-by-change: harden-core-elx-camera-ingress-and-analysis-fetch`

#### `SR-016` Go gRPC insecure-default and weak SPIFFE identity binding
- Severity: High
- Exploitability / Preconditions: caller omits a security provider or security config, or deploys SPIFFE mode without a pinned `server_spiffe_id` / trust-domain policy.
- Affected Paths:
  - `go/pkg/grpc`
- Impact:
  - `NewClient` silently falls back to plaintext transport when no `SecurityProvider` is supplied, and `NewSecurityProvider` returns `NoSecurityProvider` when config is nil or mode is empty, creating a fail-open transport downgrade path
  - the SPIFFE client path defaults to `AuthorizeAny` with no `server_spiffe_id`, and the server path defaults to `AuthorizeAny` when no trust domain is configured, so workload identity binding can degrade from exact peer validation to any-SPIFFE acceptance
- Remediation Guidance:
  - remove implicit insecure defaults from the shared gRPC package and require explicit opt-in for `none` mode in narrowly-scoped dev/test call sites
  - require pinned server identity or at least explicit trust-domain configuration for SPIFFE client/server credentials, and fail closed when identity constraints are absent
- Disposition: `covered-by-change: harden-go-grpc-security-defaults-and-spiffe-identity-binding`

#### `SR-017` Bootstrap core template registration insecure transport fallback
- Severity: High
- Exploitability / Preconditions: operator or deployment leaves `CORE_SEC_MODE` empty or sets it to `none` while bootstrap tooling is permitted to reach a core gRPC endpoint.
- Affected Paths:
  - `go/pkg/config/bootstrap`
- Impact:
  - bootstrap tooling that publishes configuration templates to core falls back to `insecure.NewCredentials()` when `CORE_SEC_MODE` is omitted or `none`, so template registration can cross the control-plane trust boundary over plaintext instead of authenticated transport
  - this downgrades an internal bootstrap/configuration path silently on misconfiguration, which is the same fail-open pattern already removed from the shared gRPC package
- Remediation Guidance:
  - require explicit secure transport configuration for bootstrap-to-core gRPC registration and reject empty or insecure `CORE_SEC_MODE` values in this package
  - keep transport setup aligned with the hardened `go/pkg/grpc` package so bootstrap callers cannot reintroduce plaintext defaults locally
- Disposition: `covered-by-change: harden-bootstrap-core-transport-defaults`

#### `SR-018` Rust edge onboarding token and transport trust gaps
- Severity: High
- Exploitability / Preconditions: attacker can influence onboarding token contents, an operator passes `--host` / `CORE_API_URL`, or deployment leaves a bare host without scheme in Rust onboarding configuration.
- Affected Paths:
  - `rust/edge-onboarding`
- Impact:
  - the Rust onboarding crate still accepts legacy/raw token formats and `edgepkg-v1` structured tokens, so it does not match the signed-only onboarding contract already enforced in the Go and Elixir onboarding paths
  - `parse_token` allows `fallback_core_url` / `--host` to override the token’s embedded API URL, recreating the same host-trust gap that was already removed from other onboarding implementations
  - package download silently defaults a bare host to `http://`, allowing plaintext bootstrap transport instead of authenticated HTTPS-only delivery
- Remediation Guidance:
  - remove legacy/raw token parsing and require the current signed token format only
  - stop letting operator-supplied host overrides replace the token’s authenticated API URL
  - require explicit `https://` core URLs for package download and reject plaintext or scheme-less bootstrap endpoints
- Disposition: `covered-by-change: harden-rust-edge-onboarding-token-and-transport-trust`

#### `SR-019` Helm shared-secret defaults for onboarding and cluster membership
- Severity: High
- Exploitability / Preconditions: deployment uses the chart defaults or does not explicitly override generated secret inputs before install/upgrade.
- Affected Paths:
  - `helm/serviceradar`
- Impact:
  - the chart seeds `secrets.edgeOnboardingKey` in [values.yaml](/home/mfreeman/serviceradar/helm/serviceradar/values.yaml) with a fixed base64 value, and the secret-generator job consumes that override in [secret-generator-job.yaml](/home/mfreeman/serviceradar/helm/serviceradar/templates/secret-generator-job.yaml), so distinct installs can share the same onboarding signing key by default
  - the chart also defaults the internal ERTS cluster cookie to `serviceradar_dev_cookie` in [values.yaml](/home/mfreeman/serviceradar/helm/serviceradar/values.yaml), and injects it into core, web-ng, and agent-gateway in [core.yaml](/home/mfreeman/serviceradar/helm/serviceradar/templates/core.yaml), [web.yaml](/home/mfreeman/serviceradar/helm/serviceradar/templates/web.yaml), and [agent-gateway.yaml](/home/mfreeman/serviceradar/helm/serviceradar/templates/agent-gateway.yaml), creating predictable shared cluster credentials across installs
- Remediation Guidance:
  - stop shipping a fixed onboarding signing key in chart defaults and generate a unique value per install when no explicit override is provided
  - generate a unique cluster cookie per install instead of templating a static development cookie into runtime pods
  - document the rotation/override behavior so operators can supply their own values safely when needed
- Disposition: `covered-by-change: harden-helm-generated-secret-defaults`

#### `SR-020` Helm SPIRE exposure and attestation defaults
- Severity: High
- Exploitability / Preconditions: deployment enables `spire.enabled=true` and uses chart defaults or does not explicitly harden the SPIRE service/agent settings.
- Affected Paths:
  - `helm/serviceradar`
- Impact:
  - the chart publishes the SPIRE server as a `LoadBalancer` by default in [values.yaml](/home/mfreeman/serviceradar/helm/serviceradar/values.yaml), and [spire-server.yaml](/home/mfreeman/serviceradar/helm/serviceradar/templates/spire-server.yaml) exposes both the SPIRE gRPC server on `8081` and the health endpoint on `8080` through that service, expanding a sensitive identity-plane surface to external networks by default
  - the SPIRE agent config in [spire-agent.yaml](/home/mfreeman/serviceradar/helm/serviceradar/templates/spire-agent.yaml) sets `skip_kubelet_verification = true` in the Kubernetes workload attestor, weakening workload attestation assurances if the local kubelet path is spoofed or intercepted
- Remediation Guidance:
  - make the SPIRE server service internal-only by default, and require explicit operator opt-in before publishing it externally
  - avoid exposing the SPIRE health port outside the cluster unless the operator intentionally requests it
  - remove the `skip_kubelet_verification = true` default or gate it behind an explicit escape hatch that is clearly documented as insecure
- Disposition: `covered-by-change: harden-helm-spire-exposure-and-attestation-defaults`

#### `SR-021` Agent release downloads leave the authenticated or signed origin via redirect
- Severity: High
- Exploitability / Preconditions: attacker can cause an initial signed or gateway-authenticated release artifact URL to return an HTTPS redirect, or rely on repository/object-storage redirect infrastructure to move the actual download to a different origin.
- Affected Paths:
  - `go/pkg/agent`
- Impact:
  - the self-update path in [release_update.go](/home/mfreeman/serviceradar/go/pkg/agent/release_update.go) only checks that redirect hops stay on HTTPS, so a signed direct artifact URL or a gateway-authenticated artifact transport request can be redirected to a different host
  - for gateway-served artifact delivery, this breaks the intended identity-bound download contract by allowing the agent to leave the gateway origin after the first authenticated request
  - for signed direct artifact URLs, this weakens provenance by treating the manifest-signed origin as advisory rather than authoritative
- Remediation Guidance:
  - bind release downloads to the initial origin and reject redirects that change scheme, host, or effective port
  - keep redirect allowance limited to same-origin path changes only, so signed URLs and gateway-authenticated delivery remain origin-bound
  - update future agent release-management contracts to stop depending on cross-origin repository redirects
- Disposition: `covered-by-change: harden-agent-release-download-redirect-trust`

#### `SR-022` Core-ELX boombox relay capture paths use predictable global temp files
- Severity: Medium
- Exploitability / Preconditions: local attacker has filesystem access on the core-elx host or container runtime namespace where the global temp directory is shared.
- Affected Paths:
  - `elixir/serviceradar_core_elx/lib`
- Impact:
  - the external boombox worker in [external_boombox_analysis_worker.ex](/home/mfreeman/serviceradar/elixir/serviceradar_core_elx/lib/serviceradar_core_elx/camera_relay/external_boombox_analysis_worker.ex) writes relay-derived H264 payloads to `System.tmp_dir!()` using `System.unique_integer/1`
  - the boombox sidecar in [boombox_sidecar_worker.ex](/home/mfreeman/serviceradar/elixir/serviceradar_core_elx/lib/serviceradar_core_elx/camera_relay/boombox_sidecar_worker.ex) also defaults output files to predictable names under the global temp directory
  - on shared hosts this creates the usual local symlink / precreation / disclosure risk around transient relay media samples before cleanup runs
- Remediation Guidance:
  - move boombox capture staging to secure random temp directories or exclusive file allocation under a private ServiceRadar temp root
  - centralize the helper so both external-worker and sidecar capture paths use the same secure allocation and cleanup pattern
  - add focused tests for secure temp-path generation and cleanup semantics
- Disposition: `covered-by-change: harden-core-elx-boombox-tempfile-handling`

## Accepted Risk Register

No accepted-risk entries have been recorded yet in this baseline artifact.

## Remaining Primary-Scope Gaps

The following primary-scope passes still need dedicated review evidence before the primary audit can be considered complete:

## Next Pass Queue

Recommended next review order:
1. `go/pkg/datasvc`
