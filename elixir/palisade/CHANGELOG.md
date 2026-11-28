# Changelog

All notable changes to palisade are recorded here. The project follows
[Semantic Versioning](https://semver.org/).

## 0.2.0 - unreleased

### Added

- `Palisade.Plug.SecurityHeaders`: content security policy from a keyword
  list (enforce or report-only, optional report URI), HSTS on HTTPS or when
  forced, `Permissions-Policy`, `Referrer-Policy`, `X-Content-Type-Options`
  and `X-Frame-Options`, with a strict same-origin default policy.
- `Palisade.ClientIP` and `Palisade.Plug.RemoteIP`: client address
  resolution that reads `X-Forwarded-For` only from trusted proxy CIDRs,
  bounded by header bytes, address count and header count.
  `ClientIP.from_connect_info/2` resolves LiveView connect info the same way.
- `Palisade.RateLimit` behaviour, `Palisade.RateLimit.ETS` (single-node
  sliding-window counter on a bounded table that denies new keys when full)
  and `Palisade.Plug.RateLimit` (named buckets, `x-ratelimit-*` and
  `retry-after` headers, JSON or HTML 429, custom denial callback).
- `Palisade.ConnectionLimiter`: global and per-key caps on active
  connections and on admission rate, with slots released when the owning
  process exits.
- `Palisade.Plug.RequestGuard`: rejects GET and HEAD requests with a body or
  `transfer-encoding`, over-long query strings, too many headers, and query
  parameters outside an optional allow-list.
- `plug ~> 1.14` dependency.

### Changed

- `NetworkAddressPolicy.cidr_contains?/2` and `ip_in_any_cidr?/2` match an
  IPv4-mapped IPv6 address (`::ffff:10.0.0.5`) against IPv4 CIDRs, and an
  IPv4 CIDR written in mapped form against IPv4 addresses. Malformed address
  tuples and non-list CIDR arguments now return `false` instead of raising.

### Fixed

- The hex.pm "Source" link points at the GitHub repository. The published
  0.1.0 package linked to a retired host.

## 0.1.0

- `Palisade.NetworkAddressPolicy`, `Palisade.OutboundURLPolicy` and
  `Palisade.OutboundFetch`.
