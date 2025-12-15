# Change: Add `serviceradar-web-ng` Phoenix foundation (side-by-side)

## Why
- We want to incrementally migrate the ServiceRadar UI and API surface from the current Next.js + Go HTTP API split to a Phoenix LiveView application without disrupting existing deployments.
- `serviceradar-core` remains the high-throughput ingestion daemon; however, the new UI/API work should begin without coupling to the existing Core HTTP APIs.
- We want a first-class Elixir abstraction for Apache AGE graph queries (ported from the reference `guided/` app) and an embedded SRQL execution path (Rustler NIF) that does not rely on the existing SRQL HTTP service.

## What Changes
- Add a new Phoenix LiveView application named `serviceradar-web-ng` that runs alongside `serviceradar-web` (Next.js) during migration.
- The new Phoenix application source SHALL live in the repository under `web-ng/`.
- `serviceradar-web-ng` connects directly to the existing CNPG/Timescale/AGE Postgres database via Ecto (read-only schemas first).
- Port/derive `ServiceRadarWebNG.Graph` from the reference `guided/guided/lib/guided/graph.ex` module, updating the graph name to `"serviceradar"` and adding safe parameterization patterns.
- Embed the Rust SRQL engine (`rust/srql`) into the BEAM using Rustler, exposing an Elixir module (`ServiceRadarWebNG.SRQL`) that executes SRQL without calling the existing `/api/query` service.
- Add minimal UI surfaces (health + query playgrounds) to validate DB connectivity, AGE queries, and SRQL embedding early.

## Non-Goals
- `guided/` is a reference/sample app and is NOT part of ServiceRadar runtime; `serviceradar-web-ng` MUST NOT depend on `guided` as a deployed component.
- No changes to `serviceradar-core` ingestion behavior, gRPC surfaces, or deployment topology.
- No dependency on the existing Core HTTP API or the existing SRQL HTTP service for `serviceradar-web-ng`.
- No wholesale port of the current Next.js UI in this change; this is the foundation for incremental feature delivery.
- No schema ownership handover (Ecto migrations) in this change; that comes later after a validated snapshot/structure baseline.

## Impact
- Affected specs: new `serviceradar-web-ng` capability (foundation, DB access, AGE graph, embedded SRQL).
- Affected code:
  - New Phoenix application (new directory; Mix project + assets).
  - Docker Compose: optional new service and Nginx routing to expose `serviceradar-web-ng` without replacing Next.js.
  - Kubernetes: optional new Deployment/Service/Ingress rules for demo environments.
- Security considerations:
  - `serviceradar-web-ng` introduces a new auth boundary; initial auth strategy must not weaken existing security guarantees.
  - Rustler NIF code must be panic-safe to avoid taking down the BEAM.

## Status
- Proposed (spec-first; do not implement until approved).
