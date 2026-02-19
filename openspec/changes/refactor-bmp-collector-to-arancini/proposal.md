# Change: Refactor BMP Collector Integration to Arancini

## Why
ServiceRadar currently has a BMP publication path aligned to a risotto-style pipeline and an in-repo BMP publisher scaffold that ingests pre-decoded NDJSON. We now need a production BMP ingress collector that can ingest raw BMP sessions at high throughput and publish directly to JetStream for the Broadway causal consumer already in this branch.

We also need to keep `arancini` as a standalone upstream project so external adopters can use and contribute to it independently, rather than coupling it to the ServiceRadar monorepo.

## What Changes
- Standardize ServiceRadar BMP ingestion on a dedicated `serviceradar-bmp-collector` runtime built with `arancini-lib` as an external dependency.
- Keep `arancini` standalone (no monorepo ownership requirement); ServiceRadar consumes released crate versions or pinned git revisions.
- Preserve the existing JetStream/Broadway integration contract for downstream consumers:
  - Stream: `BMP_CAUSAL`
  - Subject namespace: `bmp.events.>`
  - Event envelope fields required by the causal signals processor.
- Replace NDJSON-only publication assumptions with live BMP socket ingest semantics and explicit backpressure/ack behavior.
- Add compose/deployment wiring for the BMP collector consistent with existing external collectors (flowgger, trapd, netflow).

## Impact
- Affected specs:
  - `observability-signals`
  - `docker-compose-stack`
- Affected code (expected):
  - `rust/bmp-collector/*`
  - `docker-compose.yml`
  - `docker/compose/*` BMP collector config templates
  - image packaging/build wiring for BMP collector
  - Broadway/EventWriter BMP pipeline compatibility tests
- Breaking changes:
  - No downstream subject/stream breaking change is planned; migration is collector-runtime internal.
