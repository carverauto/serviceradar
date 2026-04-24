## Context
The auth stack already has strong hardening in several places, but current behavior still leaves a few token and federation boundary gaps:
- API requests verified through Guardian accept any signed token type when `expected_type` is omitted
- the rate limiter serializes access through a GenServer but still stores all historical timestamps for a key until cleanup
- SAML assertion target validation treats missing audience/recipient as acceptable
- OIDC verification treats nonce as optional and user-claim extraction does not fail closed on missing identity fields

These are all correctness/security issues within existing behavior, but they span multiple auth/federation modules.

## Goals / Non-Goals
- Goals:
  - ensure refresh tokens cannot be used as bearer API tokens
  - keep rate-limiter state bounded per active window
  - require SAML assertions to be explicitly bound to this SP
  - require nonce and identity claims for OIDC provisioning
- Non-Goals:
  - redesign token formats
  - redesign SSO provisioning beyond required-claim validation
  - replace the auth rate limiter with a distributed system

## Decisions
- Decision: when no explicit token type is requested, Guardian will allow only `access` and `api`.
  - Rationale: refresh tokens should never authorize normal API requests.
- Decision: prune the rate-limiter attempt list on insertion, not only during periodic cleanup.
  - Rationale: keeps memory and per-call cost bounded.
- Decision: SAML audience and recipient become required whenever their expected values are configured.
  - Rationale: missing target constraints are not acceptable for SP-bound assertions.
- Decision: OIDC ID token verification will require a nonce parameter and user extraction will return an error for missing `sub`/`email`.
  - Rationale: these are required identity and replay-protection inputs for our provisioning path.

## Risks / Trade-offs
- Tightening SAML/OIDC validation may reject misconfigured identity providers that previously worked.
  - Mitigation: return explicit errors and document required claims/targets.
- Requiring nonce at the verifier boundary means existing callers must be updated in lockstep.
  - Mitigation: patch controller call sites and tests together.

## Migration Plan
1. Tighten Guardian default token-type checks and API pipeline expectations.
2. Bound rate-limiter state on writes.
3. Require SAML target constraints when expected values are configured.
4. Require OIDC nonce/identity claims and update controller/tests.

## Open Questions
- None.
