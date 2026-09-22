# Tasks

## 1. Stop the bleeding (identifier hygiene + merge guards) — ships first, no data change

- [x] 1.1 Split multi-value MAC fields in the Go agent Armis path: `primaryMAC()`/`addArmisTopLevelFields` emit atomic MACs (`go/pkg/agent/sync_runtime.go:1109,1213-1216`); update sync runtime tests.
- [x] 1.2 Harden `IdentityReconciler.normalize_mac` + `maybe_add_identifier`: split on comma, require exactly 12 hex chars post-normalization, reject otherwise with telemetry counter (`identity_reconciler.ex:1774-1786,1844-1859`).
- [x] 1.3 Derive MAC confidence from IEEE local bit in the sync identifier build path instead of hardcoded `:strong` (`sync_ingestor.ex:1062-1077`); route identifier writes through validation (no raw `insert_all` bypass of constraints).
- [x] 1.4 Add strong-identity guard to alias merges: `maybe_merge_ip_alias_device` (`identity_reconciler.ex:379-400`) and `attempt_alias_merge` (`sync_ingestor.ex:2284-2313`) must refuse to merge devices with distinct `agent_id` identifiers and invalidate the conflicting alias state (audited).
- [x] 1.5 Add per-pair merge cooldown + oscillation breaker using `merge_audit` pair history; blocked re-merges emit telemetry/alert.
- [x] 1.6 Make deterministic-UID and identifier resolution consult merge_audit canonical mapping before creating devices (no tombstone resurrection); stop embedding the volatile MAC list in deterministic UID input (`identity_reconciler.ex:416-451`).
- [x] 1.7 Replace silent `device_id` replace-on-conflict in `bulk_upsert_identifiers` (`sync_ingestor.ex:1286-1305`) and `DeviceIdentifier` upsert (`device_identifier.ex:150-166`) with audited rebind operations.
- [x] 1.8 Fix demo faker: seed historical MAC generation deterministically per device (`go/cmd/faker/main.go:1408-1480`), fix PVC persistence permission failure (helm volume fsGroup/initContainer), verify `loadFromStorage` restores MAC sets across restarts.
- [ ] 1.9 (deploy-gated) Verify in demo: no new comma-blob identifiers, no new `ip_alias_conflict` oscillation audits for 48h.

## 2. Stable integration identity (before connector resume)

- [x] 2.1 Define versioned Proxmox `integration_id` format (`proxmox:v2:<cluster>:<kind>:<vmid>`) in the Proxmox plugin + enrichment ingestors; stop minting name- or MAC-keyed refs (`proxmox_enrichment_ingestor.ex:433-462`, `go/cmd/wasm-plugins/proxmox/`).
- [x] 2.2 Add reconciliation bridges through `IntegrationIdentity.legacy_candidates/2` and `lookup_values/1`; the current supported formats are owned by `IntegrationIdentity` (see [identifier vocabulary](../../../docs/docs/dire-identity-model.md#identifier-vocabulary)).
- [x] 2.3 Fix `DeviceDiscoveryIngestor` integration_id minting so rotating MACs cannot rotate the id (`device_discovery_ingestor.ex:163-175`).
- [x] 2.4 Fix batch attribution: integration identifiers register only on the device resolved per-update; eliminate 500-per-batch collapse via batch-local IP fallback (`sync_ingestor.ex:713-788`).

## 3. Restore the Proxmox connector

- [ ] 3.1 (separate branch in review) Land/verify `fix/bumblebee-gateway-catalog-delivery` so agent config delivery unblocks (currently deadlocks all plugin/config pushes on agent 1.2.99).
- [x] 3.2 Add credential-broker grant resolution to the inventory plugin execution path (grants → `api_token`), with resolution audit rows; stop-gap acceptable: policy materialization injects refreshed token material into assignment params. Done core-side at config delivery: `Plugins.CredentialBrokerDelivery` refreshes the embedded grant payload (re-mints on expiry, never delivers expired material) and `SecretRefs.resolve_runtime_params/3` resolves the secret through `SecretBroker.resolve_with_grant` (`audit?: true` → one `credential_secret_resolution_audits` row per resolution); rotating grant payloads are excluded from the config version hash. Needs 3.1 to land before agents actually receive the refreshed config.
- [x] 3.3 Ensure plugin artifact download tokens refresh with config delivery (fix 24h-TTL HMAC token staleness causing 401s). Core: tokens were already minted per generation but `not_modified` polls never delivered them — a download-token epoch (half the token TTL, floored 5m) now folds into the config version hash so configs re-version before tokens expire. Agent: `PluginManager.ApplyConfig` no longer drops token-only refreshes (fingerprint-unchanged configs update runner/stream download credentials in place without restarts). Needs 3.1 for delivery on the wedged demo agents.
- [ ] 3.4 (live ops, after 3.1) Issue/verify Proxmox API token for pve01–pve04 (root SSH available) and confirm plugin runs succeed on agent-sr-test-pve04.
- [ ] 3.5 (live validation; persistence path reworked in 5.4) Diagnose and fix virtualization enrichment persistence (frozen 2026-05-09 despite 318 successful plugin runs on 05-21 — persistence path broken by hypervisor-enrichment refactor).
- [ ] 3.6 (live, after 3.4) Validate `add-proxmox-guest-network-identity` task 1.7 (guest NIC/IP identity against live demo data).

## 4. Production data remediation (after 1.x guards verified)

- [x] 4.1 Write remediation migration: extract first-MAC fallback for blob-only devices, delete all comma/malformed `mac` identifier rows (~12.16M rows, ~10 GB), with full audit manifest.
- [x] 4.2 Remove test debris: 21 test-artifact `ocsf_agents` rows, `agent-reip-*` devices, `k8s-pod-a/b`, and their identifiers.
- [x] 4.3 Unmerge the worker-agent chimera (`sr:fe464cc5`): recreate/untombstone per-host devices for cp2-worker1..3/cp3-worker1..2, re-point each agent's `device_uid` and `agent_id` identifier, fix `agent-dusk01`→tonka01 mislink and k8s-agent's identifier on the FAKER device, clear poisoned `device_alias_states` (10.0.2.8–.12), fix `ip='agent'` literal.
- [x] 4.4 Collapse intra-Proxmox duplicates via legacy integration_id mapping (traefik ×3, 15+ hosts ×2).
- [ ] 4.5 (live ops, after 4.1-4.4 executed in demo) `VACUUM FULL` + reindex `platform.device_identifiers`; tune autovacuum for the table; record before/after sizes.
- [ ] 4.6 (live, after remediation run) Verify in demo: every connected agent has its own device with the bolt in /devices; device_identifiers < 1M rows and stable.

## 5. Single canonical resolution path

- [x] 5.1 Remove `SyncIngestor` inline resolution: delegate to `IdentityReconciler` batch APIs; delete IP-fallback-over-strong-ID, trust-`sr:`-uid (`sync_ingestor.ex:457-529,601-638,621-632`), keeping the tenant queue/coalescing.
- [x] 5.2 Route `MapperResultsIngestor` device creation through DIRE (`mapper_results_ingestor.ex:479-481,918-920,1060-1062`) and register its identifiers.
- [x] 5.3 Unify MAC normalization across ingestors (wifi map lowercase-colon variant `wifi_map/batch_ingestor.ex:1394-1395`; hypervisor re-colonized format `proxmox_enrichment_ingestor.ex:591-609`).
- [x] 5.4 Hypervisor enrichment: resolve hosts via network identity too (not only uid/exact-case name, `hypervisor_enrichment_ingestor.ex:825-864,960-969`); stop pre-setting `device_id` that bypasses reconciliation.
- [ ] 5.5 (live/perf, after deploy) Benchmark ingest at 50k-device faker scale; verify no throughput regression after fast-path removal.

## 6. Agent identity first-class

- [x] 6.1 Agent enrollment registers host evidence: interface MACs (observer-excluded), machine-id when available, normalized hostname (medium, corroborating-only) (`agent_gateway_sync.ex:130-184`).
- [x] 6.2 Periodic agent↔device link repair job: verify/restore `ocsf_agents.device_uid` and `agent_id` identifier placement for every connected agent; audited.
- [x] 6.3 Detect-and-split when a device acquires a second connected agent's `agent_id` identifier; add `DeviceAgentAvailability` to merge reassignment (`identity_reconciler.ex:1277-1286`).
- [x] 6.4 Re-enable and fix scheduled `reconcile_duplicates`: investigate dead schedule (last enqueue 2026-02-06), make it bounded/streaming and policy-gated (`identity_reconciler.ex:774-820,1031-1263`); add schedule-health alerting.
- [x] 6.5 E2E: k8s agent pod redeploy (new pod IP + hostname suffix) resolves to the same canonical device.

## 7. Read model fixes

- [x] 7.1 Unify badge predicate: device show page derives agent status from `ocsf_agents` linkage (replace dead `agent_list` checks in `device_state_data.ex:17-23`, `device_header_components.ex:58-63`, `device_summary_components.ex:301-307`, `device_edit_components.ex:388-394`, `visibility_components.ex:1211-1217`).
- [x] 7.2 Decide and implement `device_updates` disposition (drop the dead hypertable + SRQL exposure, or implement the writer). Decided: DROP. Migration `20260610090000_drop_device_updates_table.exs` removes the retention policy + table (reversible down); SRQL entity/parser/viz/model/schema removed; web-ng default-time list updated.
- [ ] 7.3 (script authored; run against demo after deploy) Playwright check: bolt renders for every connected agent in /devices list and detail pages.

## 8. Lifecycle, telemetry, guardrails

- [x] 8.1 Implement per-(device,type) cardinality caps with supersede + retirement audit; config defaults (mac: 64, others: 8) with per-integration overrides.
- [x] 8.2 Implement TTL GC job for unseen identifiers (default 90d) with run-summary logging.
- [x] 8.3 Telemetry + alerts: identifier table growth rate, per-device cardinality anomalies, merge rate per pair, agents-without-device, devices-per-agent, validation rejections by source.
- [x] 8.4 Add 50k-device faker cardinality e2e as a release gate (bounded identifier growth across restarts + churn cycles).
- [x] 8.5 Document the identity model (identifier types, confidence rules, merge policy, lifecycle) in `docs/`.
