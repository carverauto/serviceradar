## Context
`web-ng` already exposes `/api/admin/openapi` and contains a hand-maintained OpenAPI builder module. That is enough to prove the API can be described, but not enough to serve as a public source-of-truth contract for the developer portal.

The developer portal needs:
- a stable, versioned OpenAPI artifact
- a fetch path that does not depend on privileged interactive auth
- a human-friendly UI path that maintainers can inspect while wiring portal ingestion
- confidence that the artifact reflects the API surface ServiceRadar actually ships

## Goals / Non-Goals
- Goals:
  - Make `serviceradar` the canonical owner of OpenAPI artifacts used by the developer portal.
  - Publish versioned OpenAPI JSON or YAML in a stable location that the portal can fetch.
  - Expose stable SwaggerUI and Redoc routes for the canonical Ash JSON:API document.
  - Validate the published artifact in CI so drift is caught before release.
- Non-Goals:
  - Replacing every existing API route with a new API framework.
  - Building the full portal-side rendering experience in this repo.
  - Solving every historical Swagger/OpenAPI artifact in the repo in the first step.

## Decisions

### Canonical Artifact Contract
- Define a versioned artifact contract for at least one supported API-doc version, starting with `v1`.
- Publish a machine-readable OpenAPI artifact from `serviceradar` at a stable path suitable for Forgejo raw access or another stable published endpoint.
- The artifact should be treated as the canonical document the developer portal imports.

### Scope
- Start with the current Ash JSON:API `web-ng` OpenAPI document at `/api/v2/open_api`.
- Keep the explicit admin publication route for the custom admin surface because it is already the source of truth for those controller endpoints.
- The change may later expand to additional API surfaces, but the first contract should not depend on solving every API family at once.

### Browser UI Endpoints
- Expose SwaggerUI and Redoc routes under the same `/api/v2` prefix as the Ash JSON:API OpenAPI document.
- Put those routes ahead of the Ash JSON:API `forward "/"` so they are not shadowed by the router forward.
- Use a dedicated browser-capable pipeline for these routes because the JSON pipeline only accepts `application/json`.
- Keep CSP allowances scoped to the external assets loaded by these documentation UIs instead of weakening the default application-wide browser policy.

### Validation
- CI should fail if the generated or published artifact is missing, malformed, or inconsistent with the checked-in source-of-truth generation path.
- Tests should cover both access policy and document structure for the exported OpenAPI content.

## Risks and Tradeoffs
- A checked-in generated artifact is simple to consume but adds a regeneration workflow that contributors must follow.
- A runtime-only endpoint is easy to expose but not ideal for portal ingestion if it requires auth or dynamic service reachability.
- Starting with Ash JSON:API plus the existing admin publication path keeps scope controlled, but it may not satisfy every portal API-doc use case immediately.

## Open Questions
- Should the canonical artifact live in-repo as generated content, be emitted in CI, or both?
- Should the published artifact be unauthenticated raw content from Forgejo, or should ServiceRadar expose a dedicated public docs endpoint?
