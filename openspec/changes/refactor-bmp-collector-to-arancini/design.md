## Context
ServiceRadar needs high-throughput raw BMP ingestion and deterministic publication into the existing `bmp.events.*` JetStream/Broadway pipeline. The imported `arancini` reference runtime is optimized for ingest and curation, but its default subject taxonomy and payload serialization are not a drop-in match for ServiceRadar's current Broadway contract.

## Goals / Non-Goals
- Goals:
  - Use Arancini technology for BMP ingest performance.
  - Keep `arancini` upstream standalone and reusable outside ServiceRadar.
  - Maintain ServiceRadar's existing `bmp.events.*` consumer contract.
  - Preserve replay/idempotency behavior expected by Broadway consumers.
- Non-Goals:
  - Vendor `arancini` into ServiceRadar as a first-party monorepo component.
  - Replace Broadway/EventWriter ingestion with a new consumer stack.
  - Redesign the causal signal schema in this change.

## Decisions
- Decision: Build ServiceRadar's collector as a thin adapter runtime using `arancini-lib`.
  - Rationale: This keeps ingest performance primitives while allowing ServiceRadar-specific subject and envelope contracts.
- Decision: Do not run the upstream `arancini` reference binary as-is for production ingestion.
  - Rationale: Default subject shape (`arancini.updates.*`) and payload format would require additional translation stages and increase contract drift risk.
- Decision: Track `arancini-lib` as an external dependency (released version or pinned git rev) with explicit compatibility tests in ServiceRadar CI.
  - Rationale: Preserves project separation while giving deterministic builds.

## Risks / Trade-offs
- Upstream API churn in `arancini-lib` can break integration.
  - Mitigation: Pin versions/revisions and add compatibility tests for publish contract and sample BMP fixtures.
- Performance regressions introduced by ServiceRadar envelope mapping.
  - Mitigation: Keep envelope extraction minimal, publish raw payload where feasible, benchmark with burst fixtures.
- Contract drift between collector output and Broadway expectations.
  - Mitigation: Add deterministic contract tests on `bmp.events.*` subjects and payload fields consumed by causal processors.

## Migration Plan
1. Land collector adapter changes behind existing BMP stream/subject contract.
2. Run dual-fixture validation against Broadway causal processor tests.
3. Enable collector in compose/demo profiles.
4. Remove transitional NDJSON-only runtime paths once live ingest path is validated.

## Open Questions
- Should ServiceRadar publish per-router partition hints in headers only, payload only, or both?
- Do we need tenant-prefixed BMP subjects in this phase, or keep single-deployment `bmp.events.*` and defer tenant scoping?
