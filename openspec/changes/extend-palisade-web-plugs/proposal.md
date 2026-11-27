# Change: Extend `palisade` with web-edge plugs (security headers, client IP, rate limiting, request guard)

## Why

Every public Phoenix application needs the same web-edge defenses:
- security headers with a content security policy
- client address resolution that trusts `X-Forwarded-For` only from known proxies
- rate limiting
- bounds on malformed requests

`web-ng` implements these itself:
- `plugs/security_headers.ex` (138 lines)
- `serviceradar_web_ng/client_ip.ex` (111 lines)
- `plugs/rate_limit.ex` (253 lines) on top of `serviceradar_core`'s `Security.RateLimiter` (450 lines, cluster broadcast through Horde)

Other Carver Phoenix applications carry their own copies of each.

`palisade` already exists as the shared, published home for trust-boundary code ("Shared trust-boundary primitives for CarverAutomation services"). Its `NetworkAddressPolicy` has also drifted from `serviceradar_core`'s copy: core has `ip_in_any_cidr?/2` and `cidr_contains?/2`, and palisade lacks them.

## What Changes

- **`Palisade.Plug.SecurityHeaders`.** Options-driven, with no application-env lookups. It sets:
  - HSTS, only on HTTPS requests or when configured
  - a content security policy built from a keyword list, in enforce or report-only mode, with an optional report URI
  - `Permissions-Policy`
  - `Referrer-Policy`
  - `X-Content-Type-Options`
  - `X-Frame-Options`

  It ships a strict default policy (`default-src 'none'`, `'self'` only, `frame-ancestors 'none'`).
- **`Palisade.ClientIP` and `Palisade.Plug.RemoteIP`.** They resolve the client address from the socket peer. `X-Forwarded-For` is honored only when the peer is inside configured trusted CIDRs. Parsing is bounded by byte length, address count and header count. `ClientIP.from_connect_info/2` gives LiveView sockets the same result.
- **`NetworkAddressPolicy` additions.** `ip_in_any_cidr?/2` and `cidr_contains?/2`. `serviceradar_core` then delegates to palisade, which ends the drift.
- **Rate limiting.** It has three parts:
  - `Palisade.RateLimit` behaviour: `check(key, limit, window_ms)` returns `{:allow, remaining, reset_ms}` or `{:deny, retry_after_ms}`.
  - `Palisade.RateLimit.ETS`: the single-node default. It is a bounded table that fails closed when full.
  - `Palisade.Plug.RateLimit`: named buckets keyed by client IP or a custom key function. It sets `x-ratelimit-*` and `retry-after` headers and returns a 429 response in JSON or HTML.

  The cluster-wide Horde limiter stays in `serviceradar_core` as an adapter that implements the behaviour.
- **`Palisade.ConnectionLimiter`.** Admits long-lived connections, such as LiveView mounts, against global and per-key caps on active connections and on mount rate. Slots are released when the owning process exits.
- **`Palisade.Plug.RequestGuard`.** Rejects GET and HEAD requests that carry a body or `transfer-encoding`, over-long query strings, and too many headers. It can optionally enforce a per-route allow-list of query parameters.
- **Release.** Publish as `palisade` `0.2.0`. The release fixes the hex.pm "Source" link: the published `0.1.0` points at `code.carverauto.dev`, while `mix.exs` names GitHub.
- **web-ng migration.** `web-ng` switches to the palisade security headers, client IP, request guard and rate-limit plug. Its Horde limiter remains as an adapter.

## Non-goals

- OIDC primitives (already planned for palisade, tracked separately).
- Distributed rate-limit backends inside palisade.
- Copying code from repositories outside this one. These modules are written here, based on web-ng's versions.

## Impact

- Affected specs: `palisade-web-security` (new capability).
- Affected code:
  - `elixir/palisade` (new modules and a `plug` dependency)
  - `elixir/serviceradar_core` (`NetworkAddressPolicy` delegation; the rate limiter becomes a behaviour adapter)
  - `elixir/web-ng` (plugs, client IP, CSP report sink)
  - `.github/workflows/palisade-publish.yml` (unchanged trigger)
- Related: `add-serviceradar-ui-package`.
