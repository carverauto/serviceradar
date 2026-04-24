## Context
Recent security review surfaced four distinct but related trust-boundary issues:
- bundle generators write tarballs to predictable paths in a shared temp directory before reading them back
- auth/rate-limit/audit flows trust the leftmost `X-Forwarded-For` hop when enabled
- JWT revocation state lives only in ETS, so process restart clears revocations
- GitHub plugin import treats any GitHub-verified signer as trusted when `require_gpg_for_github` is enabled

These all affect security-sensitive bootstrap, auth, and plugin delivery paths in `web-ng`.

## Goals / Non-Goals
- Goals:
  - eliminate predictable temp tarball paths
  - preserve revocation semantics across process restart
  - make forwarded client IP resolution safe behind explicit trusted proxies
  - require trusted signer identity, not just GitHub's generic `verified` flag
- Non-Goals:
  - redesign the full auth/session model
  - implement a general-purpose remote IP library dependency
  - replace GitHub import with a different provenance model

## Decisions
- Decision: add a shared secure temp file helper for tarball creation.
  - Rationale: all bundle generators use the same unsafe pattern; a shared helper reduces drift.
- Decision: persist token revocations in the database with ETS as a cache.
  - Rationale: revocation is a security property, not a best-effort optimization.
- Decision: trust forwarded IPs only when the immediate peer is a configured trusted proxy and resolve the client IP from the rightmost untrusted hop.
  - Rationale: this matches reverse-proxy deployment reality and closes spoofing of rate limiting/audit data.
- Decision: require GitHub import signer allowlist matches when signature enforcement is on.
  - Rationale: "verified" only proves GitHub validated a signature, not that the signer is one of ours.

## Risks / Trade-offs
- Persisted revocation introduces a database dependency into auth verification paths.
  - Mitigation: keep ETS cache and load-through behavior to avoid repeated DB hits.
- Trusted proxy parsing can misclassify clients if proxy config is wrong.
  - Mitigation: fail back to `remote_ip` unless both the peer and header chain validate.
- Strict signer allowlists can block imports until operators configure them.
  - Mitigation: tie allowlist enforcement to the existing GitHub signature requirement setting and return clear operator-facing errors.

## Migration Plan
1. Add shared secure tempfile helper and switch all tarball generators to it.
2. Add durable revocation storage and populate/cache entries on startup and writes.
3. Add trusted proxy config and update client IP extraction.
4. Extend plugin verification policy with trusted signer allowlist and enforce it in GitHub importer.

## Open Questions
- None.
