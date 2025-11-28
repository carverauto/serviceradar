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
- [x] 1.10 Expose identity reconciliation config via API/UI with KV-backed edits (flags, promotion, reaper, fingerprinting) and validation.
- [x] 1.11 Improve sightings UX: show why each sighting is pending (policy state/identifiers), add pagination/totals, and capture device promotion lineage in device detail views.
- [x] 1.12 Clamp faker/DIRE inputs: enforce deterministic 50k IP/hostname pairs with persisted dataset reuse, prevent IP shuffle from expanding the address set, and alert when cardinality drifts beyond tolerance.
- [x] 1.13 Fix promotion availability semantics: promoted sightings must start unavailable/unknown until probes report health; wire metrics to catch false-positive availability.
- [ ] 1.14 Add regression tests that ingest the faker dataset end-to-end (sightings → promotion) and assert device counts stay at 50k (+internal) with unreachable devices remaining unavailable.
- [x] 1.15 Publish Prometheus alert templates for identity drift/promotion metrics and include in monitoring bridge change to keep identity telemetry consumable.
- [x] 1.16 Drift mitigations: disable fingerprint gating when fingerprinting is off, pin faker Helm values to non-expanding IP shuffle defaults, and retag demo images (sha-13d9cc627541190980bbad253ae6b3484a2648a0) to keep counts anchored.

## Deployment status
- Built/pushed faker with non-expanding IP shuffle: `ghcr.io/carverauto/serviceradar-faker:sha-f29d4f40c12c4a560dfa5703d451352829637a1f` (digest `sha256:70248044ebb68d0a5dd32959cd089f06494c101b830777bae5af6c13090628f3`) and updated Helm to pin it.
- Added identity config API/UI and warning logs when RequireFingerprint is auto-disabled.
- Helm values now use an `appTag` anchor and promotion is currently disabled with `sightingsOnlyMode=true` to hold sweep data as sightings until sync delivers strong IDs.
- CNPG was truncated (sightings/identifiers/fingerprints/device_updates/unified_devices/etc.) to reset state; sync/poller/faker/core restarted for clean ingest. Need to keep sync paused or enforce sightings-only ingest to avoid rehydrating unified_devices from sweep before strong IDs arrive.
- Demo drift persists: after truncation and restart, `unified_devices` repopulated to ~16,386 (first sync chunk size + 2 internal) and stalled there. With promotion off + sightings-only, only authoritative updates should bypass sightings, so investigate whether sync payloads are still marked authoritative (service_type/device_id) or if only the first sync chunk is flowing. Next steps: pause sync/poller, log DeviceUpdate Source/ServiceType when sightings-only is enabled, force sync results into sightings, then re-truncate and confirm counts hold at 2 before letting faker/sync repopulate to 50,002.
