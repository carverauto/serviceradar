# Change: Default CNPG sslmode based on TLS configuration

## Why
`pkg/db/cnpg_pool.go:NewCNPGPool` currently defaults `sslmode=disable` whenever `ssl_mode` is unset, even when a full client TLS configuration is provided. This silently downgrades CNPG connections to plaintext and can violate production security expectations.

## What Changes
- Default `ssl_mode` to `verify-full` when `tls` config is provided and `ssl_mode` is unset.
- Reject contradictory configuration where `tls` is provided but `ssl_mode=disable` is explicitly set.
- Add unit tests covering defaulting/validation behavior and preventing future regressions.
- Document the resulting behavior and how to override `ssl_mode` for non-DNS/SAN scenarios (e.g., IP-based connections).

## Impact
- Affected specs: `cnpg`
- Affected code: `pkg/db/cnpg_pool.go`, `pkg/models/db.go` (docs/comments only), and tests under `pkg/db/`
- Compatibility:
  - **Behavioral change**: configurations that provide `tls` but omit `ssl_mode` will start enforcing TLS (previously: silently plaintext).
  - Potential new failures if hostnames do not match the CNPG server certificate (mitigation: set `ssl_mode=verify-ca` or `require`, or ensure the server cert SAN matches the configured host).

## Acceptance Criteria
- When `tls` is provided and `ssl_mode` is unset, CNPG connections negotiate TLS and default to `ssl_mode=verify-full`.
- When `tls` is provided and `ssl_mode=disable`, pool creation fails fast with a clear configuration error.
- Unit tests cover both behaviors and prevent regressions.

## Rollout Plan
- Land the code + tests, then validate in Docker Compose (CNPG TLS enabled) and in demo Helm/Kubernetes environments.
- If an environment requires IP-based DB addressing, set `ssl_mode=verify-ca` or `require`, or regenerate CNPG server certs with the correct SANs.

## References
- GitHub issue: https://github.com/carverauto/serviceradar/issues/2143
