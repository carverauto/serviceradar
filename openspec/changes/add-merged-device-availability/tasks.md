## 0. Preconditions

- [ ] 0.1 Archive `add-per-agent-availability` so that its device-inventory requirements are in `specs/` before this change archives
- [ ] 0.2 Get the user's decisions on the remaining design.md Open Questions (Q5, Q6, Q7 and Q11); Q1-Q4, Q8-Q10 and Q12 are decided
- [ ] 0.3 Fix the readers marked "fix" in design.md before stage c: `device_tab_runtime.ex:201` turning false into nil, and the `basic_summaries.ex` retired filter.

Phasing: phase 1 is sections 1 and 2 (capture plus shadow and the divergence report, no behavior change). It ships and is reviewed on demo before phase 2 (sections 3 and 4) begins.

## 1. Stage a: capture (mode `legacy`, no behavior change)

- [ ] 1.1 Migration:
  - `device_agent_availability.consecutive_down` (additive, default 0);
  - `device_availability_evidence`, `device_vantage_expectations`, `device_availability_shadow`, `device_availability_legacy` and the `inventory.availability_mode` setting (`legacy`);
  - the `ocsf_devices.availability_*` columns, populated from the projection of `is_available`;
  - the mode-aware mirror trigger that keeps `availability_state` equal to the projection of `is_available` in `legacy` and `shadow`;
  - the Armis source attribute `northbound_availability_semantics`, with existing sources set to `legacy`.
- [ ] 1.2 Source registration descriptors `{source_kind, authority_class, default_ttl, min_ttl, max_ttl}`, and Ash resources for the new tables.
- [ ] 1.3 A `BEFORE INSERT OR UPDATE` trigger on `device_agent_availability` maintains `consecutive_down` from `OLD`/`NEW` `is_available`, advancing only when `checked_at` advances. A separate `AFTER INSERT OR UPDATE` trigger marks the device dirty only when the stored result can change a decision (insert, changed value or counter, previously stale row). W4, W18 and W19 need no code change. No other ledger change; the ledger is never pruned or rewritten by availability code.
- [ ] 1.4 `Availability.record_evidence/2`, write-on-change, with decision-bearing fields written immediately and lease coalescing for unchanged observations.
- [ ] 1.5 Submit evidence from every non-ledger writer:
  - Wi-Fi map (W5; a missing status submits nothing);
  - the sync path (W6);
  - plugin discovery (W7, W13);
  - hypervisor (W8);
  - camera (W9);
  - agent liveness (W10);
  - composite checks (W11);
  - mapper (W12).
- [ ] 1.5a Legacy writers (W1-W3, W5-W11, the W14 create default) also maintain `device_availability_legacy`, write-on-change, with their full computation; legacy publishers emit only in `legacy` and `shadow`.
- [ ] 1.5b Add the plugin manifest `availability_authority` for proxmox, starlink and opentext-nom, and `inventory_declared` for the awx `enabled` flag, before shadow collection starts.
- [ ] 1.6 The composite evaluation pass materializes vantage expectations, write-on-change; every expectation change marks its device dirty.
- [ ] 1.6a `device_availability_dirty`, enqueued with `ON CONFLICT DO UPDATE` so every enqueue takes the entry's row lock. The Ash actions that change `availability_source_agent_id` or an availability source profile enqueue the affected devices in uid order before updating any device row. Ledger and evidence writers issue multi-device writes in ascending uid order and take device row locks only after them.
- [ ] 1.7 Backfill:
  - `consecutive_down` from `metadata.sweep_consecutive_failures`, capped;
  - vantage expectations;
  - `operator_policy` evidence from composite verdicts.
- [ ] 1.8 Lab-deployment proof: `is_available`, the badges and the Armis candidate rows match the previous release for a full day, and `availability_state` equals the projection of `is_available` for every device. Record WAL bytes per hour as the baseline.

## 2. Stage b: shadow (mode `shadow`)

- [ ] 2.1 `Availability.Resolver.resolve/3`, a pure function implementing Decisions 3, 5, 6 and 12.
- [ ] 2.2 Transactional resolution in the global lock order (dirty entries, then device rows, each in ascending uid order), batches of at most 500, a shadow write on change only.
- [ ] 2.3 The expiry job, paged.
- [ ] 2.3a The bounded resolver worker that drains the dirty set through `resolve_devices/2` (no-op in `legacy`, shadow writes in `shadow`). Every resolution claims its devices' dirty entries in uid order before locking device rows or reading any input; the worker waits for its claims, inline resolution claims entries it does not already hold with `SKIP LOCKED`. An invalidation after the claim re-enqueues for another pass.
- [ ] 2.4 Re-resolution on merge, unmerge and restore, with evidence moving on merge (Decision 11). Ledger reassignment unchanged.
- [ ] 2.5 Divergence report:
  - counts by legacy value, legacy badge, shadow state, `source_kind` and `authority_class`;
  - devices that would become unknown;
  - policy violations;
  - invalid pins (a pinned agent that is a negative control);
  - per-source Armis canonical push changes;
  - sample uids.
- [ ] 2.6 Run on demo and the lab deployment, including the Wi-Fi AP split, and review with the user. This review ends phase 1 and is the gate for phase 2.

## 3. Stage c: cutover (`cutover` then `authoritative`)

- [ ] 3.1 The mode switch takes an advisory lock that drains in-flight writers; writers read the mode under the shared lock.
- [ ] 3.2 Under the drained switch to `cutover`, seed `device_availability_legacy` from `is_available` before any reader switches. In `cutover`, legacy writers write only that table, computing against it, and the resolver suppresses all transition side effects.
- [ ] 3.3 The reconciliation job:
  - re-resolves every device from its current ledger rows, evidence and vantage expectations under the device lock, through `resolve_devices/2` (never copying shadow output), writing false where `is_available` is NULL;
  - refreshes the rollups once;
  - reconciles stateful alerts;
  - emits one summary event;
  - moves the mode to `authoritative` only when it has finished.
- [ ] 3.3a Rollback to `legacy`: under the drain, restore `is_available` from `device_availability_legacy` in uid-ordered pages so the mirror re-derives `availability_state`; legacy publishers resume with the mode.
- [ ] 3.4 Rollup migration: an `unknown` key, the trigger counting by state, and a narrowed `WHEN`.
- [ ] 3.5 Resolver-emitted transitions go through the outbox and are emitted only in `authoritative`. Display-only changes broadcast a UI invalidation only. `state_events.ex` publishes `is_available` only in `legacy` and `shadow`.
- [ ] 3.6 Armis runner:
  - the canonical path reads `device_availability_legacy` for `legacy` sources in every mode, and the state (withholding unknown) for `merged` sources;
  - the source settings preview and the adopt action;
  - new sources must select an agent or use `merged`;
  - the agent path is untouched.
- [ ] 3.7 SRQL:
  - the `availability`, `availability_source`, `availability_class`, `agent_reachability` and `availability_policy` fields, plus `agents_up` and `agents_total`;
  - default order by availability rank;
  - the summary `unknown` count.
- [ ] 3.8 web-ng:
  - the badge from state;
  - "up from N of M agents" and the partial-reachability marker;
  - the negative-control indicators;
  - an Unknown card and a policy-violation card;
  - the evidence section and the agent role labels on the device page;
  - the API JSON and `openapi.json`;
  - the MCP cookbook.
- [ ] 3.9 Lab-deployment proof, each check with an explicit failure branch:
  - order, count and badge agree for every device;
  - Armis agent-path candidate rows are byte-identical to stage a for the same ledger contents;
  - no per-device event burst at cutover;
  - WAL per hour is at or below the baseline.

## 4. Stage d: removal (gated on no Armis source left in `legacy`)

- [ ] 4.1 Delete the legacy writes from W1, W2 and W5-W11. Keep the compatibility table, the mode setting, the mirror trigger and the `metadata.sweep_*` keys intact through a rollback window of at least one release.
- [ ] 4.2 Remove `is_available` from the Device accept lists. Delete `:set_availability`, the unused `:available` read action and the unused `status_color` calc, or switch them to the state.
- [ ] 4.3 Delete `effective_availability/2`, `ServiceRadar.Core.ResultProcessor`, and the dead Go `service_registration.go` constructors.
- [ ] 4.4 Migration (additive, with a down migration): the backstop trigger and violations table (per Q7).
- [ ] 4.5 Rollback drill on the lab deployment: revert the stage-d release and confirm the stage-c writers resume against the retained objects.

## 4e. Stage e: cleanup (after the stage-d rollback window; the point of no easy return)

- [ ] 4e.1 Migration: strip the `metadata.sweep_*` keys in pages, and drop `device_availability_legacy`, the mirror trigger and the mode setting.

## 5. Tests (written with the implementation; the test-audit authoring gate applies)

Each contract has one owner-boundary test. No contract is replayed at another layer. Every fixture is invented: `192.0.2.0/24` addresses and `SITE01-` names.

- [ ] 5.1 **Resolver owner** (pure, table-driven, unit tier). `resolve/3` over invented ledger and evidence sets. The one table covers:
  - class ranking;
  - available-wins within a class;
  - the pin;
  - ineligible reporters;
  - hysteresis below and at the threshold;
  - the governing-class hold against lower-class evidence;
  - immediate recovery;
  - expiry to unknown;
  - stable provenance;
  - negative controls: a verified block, and a violation that counts as liveness;
  - no cross-class available-wins (a lower-class `up` sets the conflict flag);
  - an invalid pin on a negative control.
- [ ] 5.2 **Transactional owner** (DB tier, `srql-fixtures` scratch DB). `record_evidence/2` and `resolve_devices/2` against real rows:
  - two sources do not overwrite each other;
  - the device row is untouched when nothing changes (assert on `xmin`);
  - a conflict-only change updates the row without an outbox transition;
  - a transition writes one outbox row, and a rollback writes none.
- [ ] 5.3 **Ledger losslessness and counter** (DB tier). After resolution and after the expiry job, every agent's row (up, down and stale) is unchanged in value and `checked_at`. Through the real writers, two validation-scan failures (W18) advance `consecutive_down` to the threshold, and a merge reassignment (W19) leaves it unchanged.
- [ ] 5.4 **Sweep ingestion regression** (DB tier). Must fail on today's code. A device with controller `up` evidence and repeated sweep failures keeps a stable state, and its row is not rewritten per sweep.
- [ ] 5.5 **Armis agent path** (DB tier, in the existing runner suite). `candidates_query/1` with an agent selected returns identical rows whether or not availability resolution has run, including for a should-be-blocked agent. Canonical `legacy` reads the compatibility table, including for a device seeded at cutover that no legacy writer touches afterwards; canonical `merged` withholds unknown.
- [ ] 5.6 **Expiry job** (DB tier). An expired `self_report` re-resolves to unknown; an unexpired one is untouched.
- [ ] 5.6a **Invalidation** (DB tier). With `write_canonical_availability` off, two validation-scan failures (W18, unchanged code) re-resolve the device to `unavailable` before expiry; changing the pin and adding a negative-control expectation each re-resolve the device without new evidence; a steady fresh renewal through the real sweep upsert (`INSERT ... ON CONFLICT DO UPDATE`) leaves no dirty entry; and a ledger write that commits while the worker is resolving the same device (claim taken, inputs not yet committed) leaves the device queued, so the next pass resolves it from the newer result.
- [ ] 5.6b **Writer-vs-worker concurrency** (DB tier, real concurrent transactions). A sweep transaction that writes ledger rows and resolves inline, run concurrently with the worker on the same devices in both interleavings (worker claims first; writer enqueues first), and a pin change concurrent with the worker, all complete without a deadlock error, and the device ends resolved from the newest committed inputs.
- [ ] 5.7 **Merge** (DB tier, in the existing merge-engine suite). The survivor holds both devices' evidence and is re-resolved; ledger reassignment is unchanged.
- [ ] 5.8 **Cutover and rollback** (DB tier). During `cutover`, ingestion plus reconciliation publish no per-device events, and a legacy writer started before the switch cannot land after it. One summary event is published. Down evidence ingested during `cutover` is not overwritten by reconciliation from an older shadow `available`. After a rollback to `legacy`, `is_available` equals the compatibility value and `availability_state` its projection.
- [ ] 5.9 **SRQL** (Rust; extends the existing device query tables):
  - default order rank;
  - `availability:unknown`;
  - an unknown device returned with its last `is_available` boolean;
  - `agent_reachability:partial`;
  - `availability_policy:violation`;
  - unchanged `unavailable_from_agent`;
  - the summary `unknown` count.
- [ ] 5.10 **web-ng** (LiveView, at the badge and row component boundary):
  - the three states;
  - "N of M agents" with the partial marker;
  - the negative-control indicators.
- [ ] 5.11 **Backstop trigger** (DB tier). A direct `UPDATE ... SET is_available` leaves the value unchanged and appends a violation row.

## 6. Validation

- [ ] 6.1 `openspec validate add-merged-device-availability --strict`
- [ ] 6.2 Per stage:
  - focused tests;
  - `mix format` and `credo`;
  - `cargo fmt` and `clippy` on the touched crates;
  - the repository gate through no-mistakes.
