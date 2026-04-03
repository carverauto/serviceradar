# Change: Publish Versioned OpenAPI Artifacts For Developer Portal

## Why
ServiceRadar already has an OpenAPI document path in `web-ng`, but it is not yet defined as a stable, publishable source-of-truth artifact contract for the developer portal. Without a canonical publishing path, the portal either has to duplicate API docs by hand or scrape an implementation detail.

The platform should publish versioned OpenAPI artifacts from `serviceradar` so the developer portal can consume them directly while ServiceRadar remains the contract owner.

## What Changes
- Define a canonical publishing contract for ServiceRadar OpenAPI artifacts suitable for developer portal ingestion.
- Require versioned OpenAPI output for the relevant ServiceRadar API surfaces, starting with the Ash JSON:API `web-ng` surface and the existing admin document path.
- Define stable raw artifact paths or equivalent published outputs that the developer portal can consume without admin authentication.
- Expose stable SwaggerUI and Redoc routes for the Ash JSON:API OpenAPI surface.
- Require CI validation so published OpenAPI artifacts remain consistent with the implementation they describe.

## Impact
- Affected specs: `ash-api`
- Affected code:
  - `web-ng` OpenAPI generation and routing
  - `web-ng` SwaggerUI and Redoc routes
  - build/publish workflow for OpenAPI artifacts
  - tests around OpenAPI generation and artifact shape
