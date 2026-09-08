## Context
The web-ng runtime contains multiple trust boundaries where untrusted data can flow into rendering or authentication logic:
- Plugin output/details rendered in LiveView widgets.
- SAML assertions and metadata supplied by external IdPs.
- OIDC metadata/JWKS and gateway JWKS fetched over HTTP from admin-configured URLs.

The current implementation has partial controls but leaves critical gaps:
- Markdown rendering escapes raw HTML but still permits potentially dangerous links before `raw/1` insertion.
- SAML verification checks presence/shape of signatures but not full cryptographic trust guarantees.
- Outbound fetches rely on admin input with minimal SSRF hardening.

## Goals
- Enforce safe-by-default rendering for plugin markdown content.
- Ensure SAML authentication is cryptographically verified and fail-closed.
- Enforce outbound metadata/JWKS URL policy to reduce SSRF risk.
- Improve CSP so browser-side mitigations remain effective if content validation regresses.

## Non-Goals
- Redesigning the entire auth stack.
- Introducing multitenancy-specific auth routing.
- Replacing SRQL query engine behavior.

## Decisions
1. Markdown Sanitization
- Keep markdown support but add explicit sanitization step over rendered HTML.
- Allow only a conservative tag/attribute set.
- Explicitly deny dangerous protocols (`javascript:`, `data:` except tightly bounded image cases if required).

2. SAML Hardening
- Require cryptographic signature verification for accepted assertions.
- Reject responses with missing signature material instead of fallback acceptance.
- Validate critical assertion conditions (issuer and temporal constraints) and add replay protections.

3. Outbound URL Policy
- Centralize validation in one helper used by OIDC, SAML, and gateway auth fetch paths.
- Restrict schemes to `https` by default.
- Deny localhost, loopback, link-local, and RFC1918 destinations unless explicitly and safely allowlisted.
- Set conservative request options (timeouts, redirect handling).

4. CSP Hardening
- Remove broad inline allowances from `script-src`/`style-src` where possible.
- If an exception is required, constrain via nonce/hash and document rationale.

## Risks and Mitigations
- Risk: stricter sanitization breaks existing plugin displays.
  - Mitigation: snapshot tests and contract tests for approved widgets/content.
- Risk: SAML hardening breaks currently permissive IdP setups.
  - Mitigation: provide clear admin validation feedback and migration notes.
- Risk: URL policy blocks some legitimate internal enterprise IdPs.
  - Mitigation: controlled allowlist configuration with explicit audit trail.
