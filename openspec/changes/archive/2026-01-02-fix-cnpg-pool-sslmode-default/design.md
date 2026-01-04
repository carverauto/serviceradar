## Context
ServiceRadar components connect to CNPG/Timescale using `models.CNPGDatabase` and `pkg/db/cnpg_pool.go:NewCNPGPool`. Today, when `ssl_mode` is omitted, the connection URL is built with `sslmode=disable` unconditionally, which can disable TLS even when a TLS config is present.

## Goals / Non-Goals
- Goals:
  - Prevent silent TLS downgrade when operators provide TLS materials.
  - Default to a secure TLS mode that matches documented expectations.
  - Provide clear, early failures for contradictory configurations.
- Non-Goals:
  - Redesign CNPG configuration schema.
  - Implement new certificate provisioning flows.

## Decisions
- Decision: Default `ssl_mode` to `verify-full` when `tls` is configured and `ssl_mode` is unset.
  - Rationale: `verify-full` provides the strongest default (chain + hostname) and aligns with existing deployment guidance that expects `verify-full`.
- Decision: Treat `tls` + `ssl_mode=disable` as invalid and return an error.
  - Rationale: This combination is always a footgun; allowing it results in silent plaintext connections.

## Risks / Trade-offs
- Risk: `verify-full` can fail if operators connect to CNPG by IP or an alias not present in the server cert SAN.
  - Mitigation: document explicit overrides (`verify-ca` or `require`) and/or ensure CNPG server cert SAN covers the configured host.

## Migration Plan
1. Ship the defaulting + validation behavior behind the existing config model (no schema changes).
2. Update tests to lock in behavior.
3. Update operator docs to explain override behavior.
4. Roll out to demo/compose; validate CNPG connectivity in both TLS and non-TLS modes.

## Open Questions
- Should we log a structured warning when `ssl_mode` is empty and we default it (for auditability), or keep it silent?

