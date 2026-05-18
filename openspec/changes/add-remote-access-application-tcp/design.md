## Context
Teleport-style application access lets users reach private HTTP services through a proxy after SSO/RBAC checks. ServiceRadar should provide a similar operator workflow, but it must fit the existing agent-routed remote-access model:

```text
browser
  -> web-ng application access endpoint
  -> core policy/session/recording manager
  -> agent-gateway selected route
  -> existing agent-initiated control stream
  -> agent app/TCP adapter
  -> registered private upstream
```

The app/TCP adapter must never accept arbitrary browser-supplied upstream hosts, routes, credential rules, recording policy, or target identities. The upstream must be an inventory or policy resource selected by trusted ServiceRadar state.

## Goals
- Provide browser access to registered internal HTTP/HTTPS applications through an edge agent.
- Provide a later constrained TCP stream adapter for explicitly registered non-HTTP services.
- Preserve one actor, one access session, one selected agent/gateway route, one upstream resource, one policy snapshot, and one audit/recording boundary.
- Enforce SSRF/open-proxy protections before any agent opens an upstream connection.
- Record lifecycle and request metadata by default without storing response bodies unless a future explicit content-retention policy enables it.
- Keep implementation ServiceRadar-owned unless a future exact-file Teleport vendoring review approves small Apache-compatible utilities.

## Non-Goals
- Do not implement arbitrary CONNECT tunneling.
- Do not let browser clients supply upstream host, port, route, DNS name, SNI, Host header, credential rule, or TLS verification policy.
- Do not store cookies, bearer tokens, request bodies, or response bodies by default.
- Do not provide database, Kubernetes, RDP, or MCP protocol access in this proposal.
- Do not copy current Teleport `lib/srv/app` or reverse-proxy implementation code.

## Resource Model
The first implementation should introduce a registered application target resource, or extend the remote-access target model, with:

- stable target ID
- display name and inventory/device relation
- selected agent or allowed agent set
- upstream scheme: `http` or `https`
- upstream host/IP and port from trusted inventory/policy
- allowed public path prefixes
- upstream Host header and SNI value from policy
- upstream TLS verification mode and CA bundle reference
- allowed request methods and max request/response byte limits
- header allow/drop/inject policy
- cookie isolation policy
- approval and recording policy
- retention and export policy

The TCP adapter should use a separate registered TCP target resource with protocol name, upstream host/port, byte limits, idle timeout, and recording policy. It should not share the browser HTTP surface unless the target type is HTTP/HTTPS.

## Session And Routing
Application access should use the same remote-access session lifecycle pattern as SSH/SFTP:

1. User requests access to a registered application target.
2. web-ng verifies authentication and RBAC.
3. core resolves target, route, approval requirement, TLS/header policy, recording policy, and quotas from trusted resources.
4. agent-gateway sends a route-bound open frame to the selected agent.
5. The agent opens only the registered upstream address and enforces policy locally.
6. Browser traffic is proxied through the session-specific web-ng endpoint.

Session frames should stay typed rather than reusing terminal byte frames blindly. HTTP applications need request/response envelope frames so policy can audit methods, paths, status codes, byte counts, and failures. TCP can use bounded data frames with explicit connection open/close/error semantics.

## Security Controls
- SSRF: upstream host/port are selected only from trusted resources. Reject literal client overrides, redirect-to-private rebinds, and unsupported schemes.
- Open proxy: no arbitrary CONNECT. TCP targets are pre-registered and permissioned independently.
- Origin isolation: each app session uses a session-scoped browser origin/path namespace so app cookies and local storage cannot collide across upstreams.
- Header policy: strip hop-by-hop headers, ServiceRadar auth headers, proxy headers, and sensitive browser headers unless policy explicitly allows or injects them.
- Host/SNI: derive both from target policy. Reject upstream redirects that require changing Host/SNI outside policy.
- TLS: verify upstream certificates by default for HTTPS. Any insecure mode must be target-policy controlled and audit-visible.
- Upload/download: enforce request and response byte quotas, content-type policy, body buffering limits, and backpressure.
- Recording: persist lifecycle and request metadata by default. Body capture remains disabled unless a future explicit content-retention policy is approved.

## Source Reuse
Current Teleport application access code is not approved for import:

```bash
TELEPORT_SRC=$HOME/src/teleport scripts/check-teleport-license-paths.sh \
  github.com/gravitational/teleport/lib/srv/app \
  github.com/gravitational/teleport/lib/srv/app/common \
  github.com/gravitational/teleport/lib/srv/app/reverseproxy
```

The current checkout reports AGPL transitive dependencies through Teleport API/types/auth/logging/proto paths. Treat Teleport behavior as product/architecture reference only. Use Go standard library HTTP reverse proxy primitives or small Apache-compatible dependencies after explicit dependency review.

Review recorded on 2026-05-17:

- Current local Teleport checkout: `~/src/teleport` at commit `42a4eaafeefee26e52bbd32ceec9699de1e9040c`.
- Current scan result: `github.com/gravitational/teleport/lib/srv/app`, `github.com/gravitational/teleport/lib/srv/app/common`, and `github.com/gravitational/teleport/lib/srv/app/reverseproxy` are blocked for direct import because the dependency scan reports AGPL-header transitive package directories including `api/utils/iterutils`, generated API/proto directories, `api/types`, `api/types/events`, `lib/utils`, `lib/auth/*`, `lib/services`, `lib/events`, and related server packages.
- Apache-era baseline check: `TELEPORT_REF=v14.4.0` reports no AGPL headers for `lib/srv/app` and `lib/srv/app/common`; `lib/srv/app/reverseproxy` does not exist as an importable package at that ref.
- Decision for this proposal: do not import, copy, translate, or mechanically port Teleport application proxy, WebSocket, TCP, or server utility code. Current Teleport remains architecture reference only. Teleport v14 source may be consulted only as historical behavior reference unless a future exact-file vendoring review records the tag, commit, file paths, headers, dependency scan, maintenance owner, and why a ServiceRadar-owned implementation is worse.
- Approved implementation baseline: ServiceRadar-owned target/session/policy code plus Go standard library `net`, `net/http`, `net/http/httputil`, `crypto/tls`, and `context`. Any non-standard proxy, WebSocket, TCP helper, or buffering dependency must land with its own license and dependency review before use.

## Validation
- Unit tests for target/resource normalization rejecting client-selected upstreams, Host/SNI, route, credential, TLS, quota, and recording overrides.
- Policy tests for methods, path prefixes, redirects, upstream TLS modes, headers, cookies, byte quotas, and approval.
- Agent adapter tests proving it dials only registered upstreams and rejects redirects or CONNECT behavior outside policy.
- Channel/route tests proving frames are accepted only over the selected session route.
- Audit/recording tests proving metadata is recorded and bodies are not retained by default.
- Demo proof with a private HTTP echo app reachable only from an agent and an HTTPS target using a test CA.
