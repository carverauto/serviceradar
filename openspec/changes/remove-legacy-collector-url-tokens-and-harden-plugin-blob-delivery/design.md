## Context
Recent security hardening removed URL-borne tokens from edge bundle delivery, but two adjacent paths remain weaker:
- legacy collector enrollment still exposes bearer secrets in the request URL
- plugin blob distribution still relies on signed bearer URLs

The repository already has a hardened pattern for bundle delivery:
- public route
- no session auth
- token passed in header or POST body
- generated commands prompt for the token instead of embedding it

The plugin blob path should converge on that pattern rather than preserving a separate signed-URL model.

## Goals
- Eliminate remaining query-string bearer token transport for collector onboarding and plugin blob access.
- Preserve existing operator and agent workflows without requiring direct session auth on blob downloads.
- Prevent generated agent/plugin config from containing reusable bearer URLs.

## Non-Goals
- Rework plugin package signing or storage backends.
- Introduce long-lived authenticated sessions for agents.
- Change plugin assignment semantics beyond removing bearer URLs from config.

## Decisions
- Decision: remove the legacy collector enrollment GET routes entirely instead of keeping a compatibility fallback.
  - Rationale: the old route exists only to support an insecure transport pattern and duplicates safer bundle/download flows.
- Decision: use header/body token transport for plugin blob upload/download rather than query params.
  - Rationale: this matches the hardened onboarding pattern and avoids leaking signed bearer tokens through URLs.
- Decision: stop emitting direct plugin bearer URLs in generated agent config.
  - Rationale: even signed short-lived URLs are still bearer secrets and should not appear in config payloads that may be logged or cached.

## Risks / Trade-offs
- Breaking change for any old collector clients still using `/api/enroll/...?...token=...`.
  - Mitigation: docs and UI should point only at the bundle/download flow; the old path is already marked legacy.
- Plugin tooling that assumes copyable signed URLs will need to switch to header/body token requests.
  - Mitigation: preserve simple API helpers and UI actions that generate the new request form.

## Migration Plan
1. Remove legacy collector enroll routes and controller query-token handling.
2. Add header/body token extraction for plugin blob upload/download endpoints.
3. Change plugin storage URL helpers and admin UI to produce hardened requests rather than signed URLs.
4. Remove bearer plugin download URLs from generated agent config.
5. Update tests and docs.

## Open Questions
- None.
