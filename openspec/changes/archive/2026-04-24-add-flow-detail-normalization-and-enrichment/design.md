## Context
Flow-detail enrichment requested in #2746 (protocol mapping, TCP flags, service context, directional context) is currently computed ad hoc in UI/API paths. That creates repeated per-request work and inconsistent behavior across entry points.

Issue #2799 introduces a complementary requirement: maintain a daily-refreshed cloud-provider CIDR dataset for IP enrichment. This dataset should feed ingestion-time classification instead of runtime UI lookups.
Flow records also carry MACs, so adding IEEE OUI vendor attribution at ingestion provides stable endpoint context without per-request lookups.

## Goals / Non-Goals
- Goals:
  - Normalize and enrich flow-detail fields at ingestion time and persist them in CNPG.
  - Add scheduled dataset refresh jobs (daily provider CIDRs, weekly IEEE OUI) and use them in ingestion enrichment.
  - Make SRQL/API/UI consumers read canonical enriched fields without recomputing mappings.
- Non-Goals:
  - No SRQL grammar changes.
  - No threat-intel feed integration in this change.
  - No MAC OUI vendor lookup integration in this change.

## Decisions
- Decision: Ingestion-time enrichment is authoritative.
  - Protocol label mapping, TCP flag decoding, port service labeling, and directionality classification are computed before persistence.
- Decision: Persist explicit enrichment provenance.
  - Persist value + source metadata (`iana`, `cloud_provider_db`, `heuristic`, `unknown`) so downstream surfaces can show confidence and avoid hidden logic.
- Decision: Daily provider dataset refresh with last-known-good behavior.
  - AshOban job fetches rezmoss dataset daily, validates it, and atomically swaps to latest valid snapshot used by enrichment.
- Decision: Weekly OUI dataset refresh with CNPG-backed storage.
  - AshOban job fetches IEEE `oui.txt` weekly, normalizes OUI prefixes, and atomically promotes the active snapshot in CNPG.
- Decision: Demo namespace egress allow-list is managed in Helm values.
  - `values-demo.yaml` `networkPolicy.egress.allowedCIDRs` must include the resolved CIDR ranges needed to reach the provider CIDR and IEEE OUI sources.
- Decision: UI becomes display-only for enriched attributes.
  - `web-ng` reads persisted enriched fields and does not re-derive those values per request.

## Alternatives Considered
- UI-only enrichment in `web-ng`:
  - Rejected due to per-request recomputation, duplicated logic, and drift risk.
- SRQL-only runtime enrichment (without persistence):
  - Rejected because queries still pay recomputation cost and cross-surface consistency remains fragile.

## Risks / Trade-offs
- Risk: Ingestion path complexity increases.
  - Mitigation: Keep enrichment transforms pure/deterministic and cover with unit tests.
- Risk: Dataset fetch failures could stale provider classifications.
  - Mitigation: retain last-known-good snapshot, emit job telemetry/logs, and fail closed to `unknown_provider` when needed.
- Risk: OUI parsing inconsistencies from source format changes.
  - Mitigation: strict parser validation, reject malformed rows, and preserve last-known-good OUI snapshot.
- Risk: Dataset endpoint IP ranges can change and break refresh jobs under default-deny egress.
  - Mitigation: document endpoint resolution and update `values-demo.yaml` CIDRs when source IP ranges shift.
- Risk: Schema additions can impact write throughput.
  - Mitigation: use additive columns/indexes only where required for query/read paths.

## Migration Plan
1. Add additive CNPG columns/tables for enriched flow attributes and provider/OUI dataset snapshots.
2. Implement ingestion enrichment pipeline and write-path updates.
3. Add daily AshOban refresh job for cloud-provider CIDR dataset.
4. Add weekly AshOban refresh job for IEEE OUI dataset.
5. Update demo Helm network-policy CIDR allow-list for dataset endpoints.
6. Project enriched fields through SRQL/API responses.
7. Update flow-detail UI to consume persisted fields only.

## Open Questions
- Should provider classification be stored as a compact enum plus provider name, or only a free-form label?
- Do we need a backfill job to enrich recent historical flows, or only apply to new ingested records?
- Should OUI vendor attribution be stored per endpoint as denormalized text or as a foreign key to the active OUI snapshot table?
