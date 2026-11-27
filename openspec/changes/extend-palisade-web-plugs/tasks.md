## 1. Network policy

- [ ] 1.1 Add `ip_in_any_cidr?/2` and `cidr_contains?/2` to `Palisade.NetworkAddressPolicy`, with property tests for IPv4, IPv6, IPv4-mapped IPv6 and malformed input.
- [ ] 1.2 Make `serviceradar_core`'s copies delegate to palisade. Existing core tests pass unchanged.

## 2. Plugs and limiters

- [ ] 2.1 Add `Palisade.Plug.SecurityHeaders`. It covers:
  - a CSP built from a keyword list
  - enforce and report-only modes, with a report URI
  - HSTS only on HTTPS or when forced
  - `Permissions-Policy`
  - `Referrer-Policy`
  - `X-Content-Type-Options`
  - `X-Frame-Options`
  - a strict default policy
- [ ] 2.2 Add `Palisade.ClientIP` and `Palisade.Plug.RemoteIP`, with trusted CIDRs, bounded `X-Forwarded-For` parsing and `from_connect_info/2`.
- [ ] 2.3 Add the `Palisade.RateLimit` behaviour, the bounded fail-closed `Palisade.RateLimit.ETS` backend, and `Palisade.Plug.RateLimit` with response headers and JSON or HTML 429 bodies.
- [ ] 2.4 Add `Palisade.ConnectionLimiter`, with global and per-key active caps, a mount-rate limit and process-monitor release.
- [ ] 2.5 Add `Palisade.Plug.RequestGuard`, which rejects a body or `transfer-encoding` on GET and HEAD, over-long queries, too many headers, and query parameters outside an optional per-route allow-list.
- [ ] 2.6 Add tests for each module:
  - spoofed `X-Forwarded-For` from untrusted peers
  - table-full fail-closed
  - slot release when a process exits
  - report-only header naming

## 3. web-ng migration

- [ ] 3.1 Replace web-ng's security headers plug and client IP module with the palisade versions.
- [ ] 3.2 Make `serviceradar_core`'s rate limiter implement `Palisade.RateLimit`, and switch web-ng's plug to `Palisade.Plug.RateLimit` with the core adapter.
- [ ] 3.3 Run the web-ng security and router tests unchanged.

## 4. Release

- [ ] 4.1 Bump to `0.2.0`, update the CHANGELOG and README scope, and fix the package source link.
- [ ] 4.2 Get maintainer approval, then push the `palisade-v0.2.0` tag.
