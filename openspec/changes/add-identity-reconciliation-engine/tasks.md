## 1. Implementation
- [x] 1.1 Finalize data model and migrations for sightings, identifiers, fingerprints, subnet policies, and audit tables with required indexes/constraints.
- [x] 1.2 Add feature flags and Helm values for IRE, promotion thresholds, fingerprinting, and reaper profiles with safe defaults.
- [x] 1.3 Update sweep/poller/agent/sync ingestion to emit network sightings (partition/subnet, weak+middle signals) instead of creating devices when no strong ID.
- [x] 1.4 Implement registry IRE core: identifier caches, policy evaluation, promotion/merge scoring, identifier upserts, and deterministic device assignment.
- [x] 1.5 Implement policy-driven reaper for sightings and low-confidence devices, respecting subnet profiles and audit logs.
- [x] 1.6 Add API/UI surfaces for sightings, promotion queue, manual overrides, subnet policies, and merge/audit history.
- [x] 1.7 Add metrics, logs, and alerts for sightings, promotions, merges, reaper actions, and cache health; update dashboards.
- [ ] 1.8 Migration/backfill: seed subnet policies, reconcile/merge existing duplicates with audit, and ensure rollback plan.
- [ ] 1.9 Tests: unit, integration, and load for ingestion → promotion/merge flow; shadow-mode validation in demo before enabling automation.
- [ ] 1.10 Expose identity reconciliation config via API/UI with KV-backed edits (flags, promotion, reaper, fingerprinting) and validation.
- [x] 1.11 Improve sightings UX: show why each sighting is pending (policy state/identifiers), add pagination/totals, and capture device promotion lineage in device detail views.

## Deployment status
- Built all OCI images with `bazel build --config=remote $(bazel query 'kind(oci_image, //docker/images:*)')`.
- Pushed all images via `bazel run --config=remote //docker/images:push_all` (tags `sha-5f2efea89b08a34b93757be1fbe22fa31ec7c024`).
- Deployed to `demo` with Helm overriding core/web/poller/sync/agent/datasvc/tools tags to the above SHA; most pods healthy, CrashLoop pending on otel, legacy rperf-client, and trapd needing follow-up.
