## 1. Contracts and external plugin scaffold
- [x] 1.1 Add the approved proposal/spec references to the empty `serviceradar-plugin-hpna` repository and initialize a focused Go/TinyGo module using `serviceradar-sdk-go`.
- [x] 1.2 Define `plugin.yaml`, `config.schema.json`, package resources, capabilities, endpoint allowlists, producer schedule, and inventory-result disposition.
- [x] 1.3 Add fixture-driven configuration validation for default `type=Switch`, multiple query sets, every allowed filter, invalid keys/types/combinations, pagination bounds, and payload bounds.

## 2. HPNA protocol implementation
- [x] 2.1 Implement brokered OAuth token exchange and fixed `list device` wrapper calls through SDK host HTTP.
- [x] 2.2 Implement bounded retry/backoff, timeout, redirect/TLS policy, advancing `startid` pagination, multi-query deduplication, and complete-snapshot failure semantics.
- [x] 2.3 Map approved HPNA fields into SDK device discovery records with stable source IDs, serial evidence, source-specific metadata, collection ID, hashes, and safe run counters.
- [x] 2.4 Add unit/fixture tests for malformed responses, auth failures, duplicate/conflicting IDs, non-advancing pages, token redaction, oversized snapshots, and deterministic output.

## 3. SDK and agent runtime
- [x] 3.1 Add any minimal SDK helpers needed for stable source-object identity and complete inventory snapshot metadata without adding HPNA-specific SDK types.
- [x] 3.2 Add grant-scoped `form_urlencoded` host credential injection with exact host/path/method/TLS/field enforcement and comprehensive secret-leakage tests.
- [x] 3.3 Extend approved producer schedule/action handling so an inventory result is enqueued through normal plugin-result ingestion while command results remain bounded.
- [x] 3.4 Add idempotency, retry, payload-size, admission-control, and action-result regression tests.

## 4. Credential and configuration management
- [x] 4.1 Add the `hpna` credential provider profile, `device_inventory` purpose, username/password secret compatibility, static endpoint metadata, and selected-agent scope.
- [x] 4.2 Materialize HPNA assignments and short-lived grants without plaintext credentials in stored config or commands.
- [x] 4.3 Render schema-driven HPNA query settings, credential coverage, agent assignment, schedule, diagnostics, and Run Now controls with RBAC and audit coverage.
- [x] 4.4 Align provider UI work with `refactor-unified-credential-management` and `unify-plugin-credential-rules-db-surface` rather than creating a second credential store.

## 5. DIRE and inventory persistence
- [x] 5.1 Add validated manufacturer-scoped hardware-serial identifiers, normalization/placeholder rejection, confidence rules, indexes, cardinality/TTL integration, and audit metadata.
- [x] 5.2 Register hardware serial evidence from HPNA, Armis, and generic device discovery while preserving source-authoritative integration IDs.
- [x] 5.3 Add a bounded dry-run-first backfill for unique existing serial/vendor metadata; report and skip duplicates or ambiguous vendor aliases.
- [x] 5.4 Add source-observation persistence, complete-snapshot presence updates, merge reassignment, indexes, and idempotency by source instance/collection/content hash.
- [x] 5.5 Preserve existing Armis metadata while adding HPNA source fields and unioning `discovery_sources`; add cross-source merge/conflict tests.
- [x] 5.6 Verify devices without shared strong evidence stay separate with visible diagnostics rather than merging from IP/hostname alone.

## 6. Read APIs and operator visibility
- [x] 6.1 Add authenticated cursor-paginated source-inventory reads with source/instance/presence/collection filters and bounded field projection.
- [x] 6.2 Add SRQL/index coverage for `discovery_sources:(hpna)` and common HPNA source metadata filters.
- [x] 6.3 Show HPNA source details, freshness, current/absent state, and last collection on canonical device and integration views, aligned with `show-all-device-integrations-and-hierarchy`.
- [x] 6.4 Add RBAC, pagination, query-safety, stale snapshot, and API token tests suitable for the linked NCO client.

## 7. Build and deployment
- [x] 7.1 Add reproducible TinyGo tests/builds, SBOM, vulnerability scanning, and importable architecture-neutral Wasm bundle packaging.
- [ ] 7.2 Sign and publish the plugin bundle through the protected release pipeline.
- [ ] 7.3 Import and approve the signed package, assign it to the selected k8s agent in `example-namespace`, and create the scoped HPNA credential rule.
- [ ] 7.4 Run a manual credential check and complete inventory collection; compare bounded counts with an HPNA export and inspect DIRE merge/conflict samples.
- [ ] 7.5 Enable the once-daily schedule, verify command/run history and freshness over at least two collections, and test Run Now.
- [ ] 7.6 Confirm no long-lived HPNA credential or token appears in agent config, command payloads/results, logs, audit rows, plugin results, or device metadata.
- [x] 7.7 Publish the ServiceRadar source API contract and collection/field mapping needed by the linked NCO change.
