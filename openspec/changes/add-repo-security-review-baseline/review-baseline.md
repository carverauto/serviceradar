# Repository Security Review Baseline

## Status
- Review artifact version: `2026-03-29-datasvc-pass-1`
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
| `go/pkg/nats` | Secondary | not-started | Pending after primary scope closure. |
| `go/pkg/spireadmin` | Secondary | not-started | Pending after primary scope closure. |
| `go/pkg/trivysidecar` | Secondary | not-started | Pending after primary scope closure. |
| `go/pkg/scan` | Secondary | not-started | Pending after primary scope closure. |
| `go/cmd/wasm-plugins` | Secondary | not-started | Pending after primary scope closure. |
| `rust/trapd` | Secondary | not-started | Pending after primary scope closure. |
| `rust/log-collector` | Secondary | not-started | Pending after primary scope closure. |
| `rust/consumers/zen` | Secondary | not-started | Pending after primary scope closure. |
| `rust/flowgger` | Secondary | not-started | Pending after primary scope closure. |
| `rust/srql` | Secondary | not-started | Pending targeted SRQL / query-safety pass. |
| `docker/compose` | Secondary | not-started | Pending after primary scope closure. |
| `k8s/demo` | Secondary | not-started | Pending after primary scope closure. |
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
