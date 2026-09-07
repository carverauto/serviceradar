# Design: Refactor device identity reconciliation

## Context

Findings below were produced by a 10-track investigation (live demo CNPG forensics, full code reads of the reconciler/all ingestors/agent path/read models, k8s + plugin runtime diagnostics, git/openspec archaeology). Every load-bearing claim was adversarially verified against both code and live data.

### Verified root-cause chains

**Identifier explosion (12,291,808 rows, 10.2 GB):**
- `go/pkg/agent/sync_runtime.go:1213-1216` — `primaryMAC()` returns the entire comma-joined `macAddress` field; `:1134` puts it in `update["mac"]`.
- `identity_reconciler.ex:1844-1859` — `normalize_mac` strips `:`/`-`/`.` but never splits on comma, never validates 12-hex, never caps length. Values like `001AA0B94040,001422F42A2A,70B3D59EDC93` are stored verbatim as single `strong` identifiers.
- `sync_ingestor.ex:1062-1077, 1286-1305` — identifiers written via raw `Repo.insert_all` (bypasses Ash validation), confidence hardcoded `:strong`, on-conflict replaces only `device_id`/`last_seen` — rows accumulate forever; `n_tup_del = 0` since table creation; autovacuum has never run on the table.
- Live: 12,161,487 of 12,191,658 mac rows (99.75%) contain commas; all match `^[0-9A-F]{12}(,[0-9A-F]{12})+$`; avg length 191, max 2,599.
- Amplifier: demo faker regenerates random "historical" MACs each process start (`go/cmd/faker/main.go:1449-1457` unseeded `randInt`; `:1316` comma-joins 1–200 MACs/device). Its PVC persistence fails (permission error) so every restart is a new identity universe: +~44k rows/restart, up to 10 restarts/day during deploy churn (433k rows/day peak).
- Concentration: since June, canonical resolution collapse focuses new rows onto ~319 "black hole" devices (worst: 4,083 blob rows containing 82,447 distinct MACs); 217 devices hold 50,116 `integration_id`s in exact 500-per-device blocks — one 500-update batch collapsing onto one device via the sync batch path's IP fallback.

**Agent badge / device collapse (merge war, still active):**
- 2026-06-04 21:36–21:41: five `identifier_conflict` merges keyed only on `agent_id` collapsed the worker devices (guards added 2026-06-05, commit `6803fdb69`, but corrupted state never cleaned).
- `alias_events.ex:406-470` — IP aliases confirm on 3 sightings with no device-identity validation; sweep answers alone confirm aliases.
- `identity_reconciler.ex:379-400` (`maybe_merge_ip_alias_device`) and `sync_ingestor.ex:2284-2313` (`attempt_alias_merge`) — merge unconditionally on a confirmed alias row; no `agent_id`/hostname guard. Result: 184 `ip_alias_conflict` merges, same-pair ping-pong (A→B→A, 18–22× per pair) through 2026-06-10.
- `identity_reconciler.ex:416-451` — deterministic UID embeds the volatile identifier set; each agent hello resurrects tombstoned devices, feeding the loop. 17 merged-away `from_device_id`s exist again in `ocsf_devices`.
- Net: 5 of 6 worker agents' `ocsf_agents.device_uid` → one chimera (`sr:fe464cc5`, hostname `k8s-cp2-worker1`, wrong IP); real host rows tombstoned; visible per-host rows are stale Proxmox duplicates with no agent FK → no bolt. `agent-dusk01` points at tonka01's device. The k8s-agent's `agent_id` identifier sits on an Armis faker laptop (`FAKER-NET-LAP-50000`) — `resolve_identifier_conflicts` (`identity_reconciler.ex:966-981`) treats the single stale row as canonical, so it can never self-correct.
- Show-page badge checks `ocsf_devices.agent_list` (`device_state_data.ex:17-23`, `device_header_components.ex:58-63`); no Elixir writer exists (only the legacy Go model `go/pkg/models/ocsf_device.go:170`); empty for all 50,166 devices. List badge checks `ocsf_agents.device_uid` (`device_live/index.ex:852-885`). Two predicates, one dead, one poisoned by the collapse.
- 21 of 46 `ocsf_agents` rows are 2026-04-25 test artifacts (12 with NULL `device_uid` — the entire "34 of 46" identifier gap); also `agent-reip-*` simulation debris in `ocsf_devices`.

**Agent ↔ Proxmox non-merge (structural):**
- Agent enrollment registers only `{agent_id}` (`agent_gateway_sync.ex:130-172`, `:184` `mac: nil`). Proxmox devices carry only `{integration_id, mac}` and usually no IP (no QEMU guest agent). Hostname is not an identifier type. Identifier overlap = ∅ ⇒ DIRE never detects a conflict (zero Proxmox merges in 1,487 audits). Convergence only ever happened via IP-row reuse for the 13 of 115 Proxmox devices whose payload had an IP.
- `HypervisorEnrichmentIngestor` host matching uses only uid + exact-case name/hostname SQL (`hypervisor_enrichment_ingestor.ex:825-864`); unresolved records mint a deterministic uid and route through `SyncIngestor` with `device_id` pre-set, which `sync_ingestor.ex:623` trusts verbatim — bypassing reconciliation entirely.
- `integration_id` churn: name-keyed (2026-05-09 02:21) → MAC-keyed (15:11) → current code mints `proxmox:pve:<node>` / `proxmox:<kind>:<node>:<vmid>` — a third generation of duplicates guaranteed on resume.

**Proxmox connector outage (layered):**
1. 2026-05-09 16:53 — virtualization persistence froze, coinciding with the hypervisor-enrichment refactor deploy.
2. 2026-05-21/22 — plugin credentials migrated to credential-broker grants; the inventory WASM plugin has no broker code path and hard-requires a literal `api_token` → 100% of runs fail "Proxmox API token is required" (33,042 grants issued, 0 consumed; the grant baked into assignment params expired 2026-05-26).
3. 2026-06-09 — plugin artifact download 401 (24h-TTL HMAC token, stale in unrefreshed config).
4. 2026-06-09 22:55 — agent 1.2.99 restart; since then zero plugin runs because every config push fails to apply: bumblebee catalog staging failure defers all config version updates (529× "Failed to stage Bumblebee catalog assignment") — the deadlock addressed by `fix/bumblebee-gateway-catalog-delivery`.

**Systemic (why it keeps breaking):**
- `SyncIngestor` is a parallel resolution engine (`sync_ingestor.ex:457-529, 601-638, 1286-1311`) that bypasses `IdentityReconciler`; `MapperResultsIngestor` creates devices directly (`mapper_results_ingestor.ex:479-481, 918-920, 1060-1062`); wifi/hypervisor pre-mint `sr:` uids the sync path trusts blindly. Three different MAC normalizations exist across ingestors.
- The 5-minute `reconcile_duplicates` cron is enabled but dead — `ng_job_schedules.last_enqueued_at = 2026-02-06`; and its implementation streams the entire 12.3M-row table into memory and performs MAC-only/IP merges with no policy gating (`identity_reconciler.ex:774-820, 1031-1263`).
- All identifier writes are last-writer-wins with silent `device_id` repoint and no audit (`device_identifier.ex:150-166`).
- 9+ DIRE fix proposals + 3 cleanup migrations in 5 months; each cleaned data only — every pathology has measurably recurred (LAA-strong MACs back at 809,121 rows; tonka01 re-acquired the exact aliases a migration deleted, one day after cleanup).

## Goals / Non-Goals

- Goals:
  - Bound `device_identifiers` growth permanently (validation + lifecycle + GC + telemetry).
  - Converge each physical host to exactly one canonical device, stable under pod IP churn, DHCP churn, and agent restarts.
  - Make agent identity authoritative and self-healing; one bolt per connected agent in /devices.
  - Give agent and hypervisor records a shared identifier vocabulary so they merge.
  - Restore the Proxmox connector and make its identity output format-stable.
  - Make merge behavior observable, rate-limited, and reversible.
- Non-Goals:
  - Multi-tenant partition redesign (all live rows are `partition='default'`; partition semantics unchanged).
  - Replacing the OCSF device schema or SRQL device read path.
  - Real Armis API changes (faker realism is preserved — devices keep many MACs; they just stop being random per restart).
  - Graph-database identity storage (rejected: CNPG remains authoritative per `2026-01-02-fix-dire-engine`).

## Decisions

- **D1 — Identifiers are atomic, validated, normalized values.** One MAC per row, exactly 12 hex chars after normalization; reject (and count via telemetry) anything else at the boundary. Split multi-value fields in the Go agent (`primaryMAC` et al.) AND defensively in `normalize_mac`/`maybe_add_identifier` (defense in depth — other integrations exist). Confidence derives from evidence (IEEE local bit ⇒ `medium`), never hardcoded.
  - Alternatives: validate only Elixir-side (rejected: Go agent is versioned/deployed separately; both layers have history of divergence).
- **D2 — One resolution engine.** Ingestors become translators that emit `DeviceUpdate`s; only `IdentityReconciler` resolves/creates/merges devices and writes identifiers. The sync path's inline resolution (IP fallback overriding strong IDs, batch-local collapse, trust-`sr:`-uid) is deleted, not gated. Pre-set `device_id`s are treated as hints requiring re-validation.
  - Alternatives: keep fast-path with shared cache (rejected: the "fast path" is where 4 of 5 collapse bugs live; correctness first, then measure).
- **D3 — Canonical-alias model with resurrection protection.** `merge_audit` gains a queryable canonical-mapping role: deterministic-UID and identifier lookups consult the alias mapping before creating a device, so a tombstoned/merged-away ID can never be resurrected by a later update. Merges stay physical (single survivor row) but become idempotent.
  - Alternatives: full append-only observation store + periodic re-resolution (ideal entity-resolution shape, but a rewrite; staged as future work — D3 gives the invariant at a fraction of the cost).
- **D4 — Strong-identity guards and merge stability.** An IP alias (or any weak/medium evidence) may corroborate but never merge two devices that hold *distinct* strong identities (different `agent_id`s, different `integration_id` providers-refs). Per-pair merge cooldown + oscillation breaker: a (from,to) pair that has merged in either direction within the cooldown window is blocked and alerted, not re-merged. All identifier `device_id` rebinds write audit rows.
- **D5 — Identifier lifecycle.** Per-(device, type) cardinality cap (default: 64 for `mac`, 8 for others) with supersede-by-`last_seen`; volatile types get TTL-based GC (default 90 days unseen); scheduled GC job + autovacuum tuning for the table; cardinality/growth telemetry with alert thresholds. Caps are config, enforced at write time.
- **D6 — Versioned, stable integration identifiers.** See the current [identifier vocabulary](../../../docs/dire-identity-model.md#identifier-vocabulary) for the admissibility contract and authoritative format reference.
- **D7 — Bridging identifiers.** Agent enrollment registers host evidence: interface MACs (observer-excluded per existing spec), `machine_id` (from agent host telemetry) and normalized hostname (medium confidence, corroborating-only). Hypervisor enrichment registers guest NIC MACs (already structured by `add-proxmox-guest-network-identity`) and normalized hostname the same way. Result: agent and Proxmox records share MAC + hostname vocabulary; merges require strong (MAC) match with hostname corroboration, or operator confirmation.
- **D8 — Agent identity is first-class and self-healing.** Distinct connected agents MUST resolve to distinct devices; a device carries at most one connected agent's `agent_id` identifier (multi-agent collapse is detected and split). Link repair runs periodically (not only at hello): for each connected agent, verify `ocsf_agents.device_uid` points at a live, correctly-identified device; repair and audit otherwise. `device_agent_availability` joins the merge reassignment list.
- **D9 — One badge predicate.** Both /devices list and device show derive "is agent" from the `ocsf_agents → device_uid` linkage (single SQL/calc shared by both); the `agent_list` column path is removed from read models (column retained for OCSF compatibility).
- **D10 — Inventory plugins resolve credential-broker grants.** The plugin runtime resolves broker grants to secret material before invocation (or policy materialization injects token material into assignment params with refresh-on-expiry); artifact download tokens refresh with config pushes. Proxmox connector restoration is the validation case (pve01–pve04, root SSH available for API token issuance).
- **D11 — Faker realism without entropy.** Historical MAC tails become seed-deterministic (device index + stable salt); PVC persistence permission fixed (fsGroup/initContainer); load-from-storage verified on boot. DHCP-churn simulation (IP swaps with stable MACs) is exactly the scenario DIRE must converge under — it stays.

## Risks / Trade-offs

- **Purging 12.16M blob rows could orphan devices whose only identity was a blob** → re-resolution occurs naturally on next sync (faker emits continuously); migration extracts each blob's first MAC into a valid row before deleting when the device has no other identifier; run inside maintenance window; `VACUUM FULL`/reindex scheduled (~10 GB reclaim).
- **Hostname bridging risks over-merge on duplicate hostnames** (e.g. cloned VMs) → hostname is corroborating-only (never sole basis), normalized, and guarded by D4; telemetry counts hostname-corroborated merges for review.
- **Deleting the sync fast path may regress ingest throughput at 50k-device scale** → tenant-scoped queue already coalesces bursts; add batch identifier lookup (already partition-scoped) and measure; the 12.3M-row table shrinking ~99% is itself the dominant performance win.
- **Unmerging the worker-agent chimera while the alias merge war is still live would immediately re-collapse** → ordering matters: merge guards (D4) ship and are verified BEFORE the data remediation migration runs.
- **Connector resume before integration_id migration would mint a third duplicate generation** → the v2 format + legacy mapping ships before credentials are restored.

## Migration Plan

1. Ship D1 validation + D4 guards + D6 v2 format (code only, no data change). Verify merge oscillation stops (no new `ip_alias_conflict` audits for 48h).
2. Run data remediation migration (transactional, audited, with row-count report):
   a. Extract first-MAC fallback rows for blob-only devices; delete all comma/invalid `mac` identifier rows.
   b. Delete test-artifact agents (21 rows: `test-agent-*`, `local-config-agent-*`, `recover-agent-*`, `new-heartbeat-agent-*`), `agent-reip-*` devices, and their identifiers.
   c. Unmerge the worker chimera: recreate/untombstone per-host devices, re-point each worker agent's `device_uid`, move `agent_id` identifiers (including k8s-agent's off the FAKER device), clear poisoned `device_alias_states` for 10.0.2.8–.12.
   d. Map legacy Proxmox `integration_id`s to v2; collapse intra-Proxmox duplicates (traefik ×3, 15+ hosts ×2).
   e. `VACUUM FULL` + reindex `device_identifiers`; record before/after sizes.
3. Re-enable + fix the scheduled reconciliation job (bounded, streaming, policy-gated); confirm it actually enqueues.
4. Land plugin credential resolution; refresh download tokens (requires `fix/bumblebee-gateway-catalog-delivery` so config applies); restore Proxmox API token (pve01–pve04); validate `add-proxmox-guest-network-identity` 1.7 end-to-end: Proxmox guest ↔ agent device converge to one record with the bolt visible.
5. Ship lifecycle caps/GC + telemetry; add the 50k-device cardinality e2e (faker) as a release gate.
- Rollback: each step is independently revertible; remediation migration writes a full audit manifest (device/identifier rows touched) enabling targeted unmerge/restore; identifier purge is recoverable from source systems by re-sync.

## Open Questions

- Should `device_updates` (0 rows, hypertable, SRQL-exposed, no writer anywhere) be implemented as the device-history log it was designed to be, or dropped? (Leaning: drop now, design history as part of the future append-only observation store.)
- Cap defaults: is 64 MACs/device right for real Armis estates (busy switches legitimately track hundreds)? Make per-integration overrides part of enrichment rules?
- Multi-agent hosts: is >1 connected agent on one device ever legitimate (e.g. host agent + k8s agent on same node)? D8 currently says no; needs product confirmation.
