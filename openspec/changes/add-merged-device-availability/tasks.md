## 0. Preconditions

- [ ] 0.1 Archive `add-per-agent-availability` so that its device-inventory requirements are in `specs/` before this change archives
- [x] 0.2 Get the user's decisions on the remaining design.md Open Questions (Q5, Q6, Q7 and Q11); Q1-Q4, Q8-Q10 and Q12 are decided
  - Decided 2026-10-24 (design.md, Open Questions): the pin outranks `operator_policy` (Q5); event gating is a deployment setting with the sweep-group flag as a filter (Q6); no restoring trigger, an append-only violation trigger plus accept-list removal and a static check (Q7); W19 survivor-wins is out of scope (Q11).
- [x] 0.3 Pre-stage-c reader fixes in the design.md web-ng reader table: `device_row_is_available/1` and `basic_summaries.ex`

Phasing: phase 1 is sections 1 and 2 (capture plus shadow and the divergence report, no behavior change). It ships and is reviewed on demo before phase 2 (sections 3 and 4) begins.

## 1. Stage a: capture (mode `legacy`, no behavior change)

- [x] 1.1 Migration (`20261019180000_add_merged_availability_capture`; existing rows are projected by the enqueued `CaptureBackfillWorker`, because a migration may not run a synchronous backfill):
  - `device_agent_availability.consecutive_down` (additive, default 0);
  - `device_availability_evidence`, `device_vantage_expectations`, `device_availability_shadow`, `device_availability_legacy` and the `inventory.availability_mode` setting (`legacy`);
  - the `ocsf_devices.availability_*` columns, populated from the projection of `is_available`;
  - the mode-aware mirror trigger that keeps `availability_state` equal to the projection of `is_available` in `legacy` and `shadow`;
  - the Armis source attribute `northbound_availability_semantics`, with existing sources set to `legacy`.
- [x] 1.2 Source registration descriptors `{source_kind, authority_class, default_ttl, min_ttl, max_ttl}`, and Ash resources for the new tables.
- [x] 1.3 A `BEFORE INSERT OR UPDATE` trigger on `device_agent_availability` maintains `consecutive_down` from `OLD`/`NEW` `is_available`, advancing only when `checked_at` advances and recomputing when `is_available` changes at an equal `checked_at` (migration `20261025150000`, which also seeds unavailable rows left at 0). A separate `AFTER INSERT OR UPDATE` trigger appends the device to the invalidation log only when the stored result can change a decision (insert, changed value or counter, or an unchanged renewal whose previous `checked_at` is older than half the row's freshness TTL). W4, W18 and W19 need no code change. No other ledger change; availability code does not prune the ledger or change a row's stored result or timestamps.
  - Stage a: the invalidation triggers append only outside `legacy` mode, because nothing consumes the log before the stage-b worker; the switch to `shadow` starts from a full resolution. A moved row (W19), a changed sweep group and a changed reporter expectation also append, since each can change a decision.
- [x] 1.4 `Availability.record_evidence/2`, write-on-change, with decision-bearing fields written immediately and lease coalescing for unchanged observations.
- [x] 1.5 Submit evidence from every non-ledger writer (capture only, best effort, switchable with `SERVICERADAR_AVAILABILITY_EVIDENCE_CAPTURE`):
  - Wi-Fi map (W5; a missing status submits nothing);
  - the sync path (W6);
  - plugin discovery (W7, W13);
  - hypervisor (W8);
  - camera (W9);
  - agent liveness (W10);
  - composite checks (W11);
  - mapper (W12).
  - The sync path records only registered sources: the Go `DeviceUpdate.IsAvailable` is a plain boolean, so an unregistered sync source's value is not evidence (design, Go readers).
- [ ] 1.5a Legacy writers (W1-W3, W5-W11, the W14 create default) also maintain `device_availability_legacy`, write-on-change, with their full computation; legacy publishers emit only in `legacy` and `shadow`.
  - Stage a (done): in `legacy` and `shadow` an `ocsf_devices` trigger copies every change of the value the legacy writers computed (`is_available`, including the create default) into the table, write-on-change. The publishers still emit unconditionally, which is the same thing while `legacy` is the only reachable mode.
  - Stage c: in `cutover` and `authoritative`, sweep, sync, camera and composite writers compute against the compatibility table and write only it, reading the mode under the shared lock. An agent check-in reads `Mode.current/0` without that lock (`LegacyWrites`). Legacy publishers emit only in `legacy` and `shadow`.
- [x] 1.5b Add the plugin manifest `availability_authority` for proxmox, starlink and opentext-nom, and `inventory_declared` for the awx `enabled` flag, before shadow collection starts.
- [x] 1.6 The composite evaluation pass materializes vantage expectations, write-on-change; every expectation change appends its device to the invalidation log.
- [x] 1.6a `availability_invalidations (id bigserial, device_uid, enqueued_at)`, written only by plain `INSERT` (no `ON CONFLICT`, no reads) from the ledger `AFTER` trigger, an `AFTER UPDATE` trigger on `availability_source_agent_id`, the expectation trigger and the availability source profile update path.
  - The profile path needs no code: the profile materializer writes the profile's agent into `availability_source_agent_id`, which the column trigger catches.
- [x] 1.7 Backfill:
  - `consecutive_down` from `metadata.sweep_consecutive_failures`, capped;
  - vantage expectations;
  - `operator_policy` evidence from composite verdicts.
  - `consecutive_down` is seeded by `CaptureBackfillWorker`. Vantage expectations and `operator_policy` evidence are written by each enabled check's next full evaluation pass, which recomputes the verdicts they would be copied from.
- [ ] 1.8 Lab-deployment proof: `is_available`, the badges and the Armis candidate rows match the previous release for a full day, and `availability_state` equals the projection of `is_available` for every device. Record WAL bytes per hour as the baseline.

## 2. Stage b: shadow (mode `shadow`)

- [x] 2.1 `Availability.Resolver.resolve/3`, a pure function implementing Decisions 3, 5, 6 and 12.
  - Ledger decisions record `source_kind` `agent_probe` (instance: the sweep group). Before a device's first shadow decision, its previous state is the legacy mirror, which is also what the resolver sees at cutover.
- [x] 2.2 Transactional resolution: device rows locked in uid order, batches of at most 500, a shadow write on change only; resolution never reads or waits on the invalidation log.
  - `Availability.Resolution`. The change test compares state, provenance, conflict and agent counters with the stored shadow row under the device lock, so an unchanged device is not written. In `legacy` the inline gate is a cached mode read (`Availability.Mode`, 30 s), with no query. An inline failure defers the devices to the log instead of failing the write.
  - Measured on a scratch database (200 devices, 50 of them with controller `up` evidence and failing sweeps; 10 steady sweeps plus 10 controller resubmissions): 0 shadow writes, 0 log appends, 0 evidence writes in `shadow`; ledger (2 000) and device-row (3 000) updates identical to `legacy`.
- [x] 2.3 The expiry job, paged.
  - `ExpiryWorker`, every minute: from `availability_settings.expiry_watermark` (set on entering `shadow`) in slices of at most 10 minutes, pages of 500 devices whose evidence `expires_at` or ledger `checked_at + ttl` fell in the slice (new index `device_agent_availability_checked_at_idx`, built concurrently). The watermark advances only after the slice. A change of a sweep group's interval, or its deletion, moves its rows' windows, which the watermark cannot follow, so outside `legacy` a `sweep_groups` trigger appends every device with a ledger row in that group to the invalidation log.
- [x] 2.3a The bounded resolver worker: in one transaction it claims the oldest visible log rows (`DELETE ... WHERE id IN (SELECT ... ORDER BY id LIMIT n FOR UPDATE SKIP LOCKED) RETURNING`), deduplicates by device uid, resolves at most 500 devices in uid order (re-appending any overflow), and commits; rows from uncommitted writers stay for a later pass. It consumes without resolving in `legacy` and writes shadow rows in `shadow`. The sweep ingestor, `record_evidence/2` and the merge transaction always resolve inline in their own transaction and never touch the log.
- [x] 2.4 Re-resolution on merge, unmerge and restore, with evidence moving on merge (Decision 11). Ledger reassignment unchanged.
  - Merge moves evidence in every mode (later `observed_at` wins on a key both devices hold) and resolves the survivor inline; unmerge resolves both devices inline. Restores go through the log: a trigger appends a restored tombstone (and a new device) outside `legacy`, because one restore path is a raw upsert that no inline call can reach. `record_evidence/2` locks device rows before evidence rows, the merge's order, and drops devices tombstoned meanwhile.
- [x] 2.5 Divergence report:
  - counts by legacy value, legacy badge, shadow state, `source_kind` and `authority_class`;
  - devices that would become unknown;
  - policy violations;
  - invalid pins (a pinned agent that is a negative control);
  - per-source Armis canonical push changes;
  - sample uids.
  - `Availability.DivergenceReport` (read-only transaction, statement timeout, one aggregate pass per section), printed by `Availability.Operator.report/1` (`bin/serviceradar_core rpc` or `eval`) and `mix serviceradar.availability.report`. It also reports R5: evidence flips to `down` within half a lease of the stored `up` (marked by `EvidencePlan` in the record's `detail`) and decisions within half a lease of a disagreeing observation.
  - Entering `shadow` (`Mode.enter_shadow/1`, `mix serviceradar.availability.mode shadow`) enqueues one full paged resolution and seeds `device_availability_legacy` for every device (write-on-change, `SKIP LOCKED`); `legacy` is the rollback and drops the shadow rows.
- [x] 2.6 Run on demo and the lab deployment, including the Wi-Fi AP split, and review with the user. This review ends phase 1 and is the gate for phase 2.
  - Reviewed 2026-10-24 on the demo report (design.md, "Phase-1 review"). The user confirmed the Wi-Fi AP split: the managing controller wins over a failing sweep.

## 3. Stage c: cutover (`cutover` then `authoritative`)

> Superseded in part by `simplify-merged-availability-rollout`: the modes, the mode switch, the drained cutover and the rollback (3.1, 3.2, 3.3a) are removed; every install converges once on upgrade.

- [ ] 3.1 The mode switch takes an advisory lock that drains in-flight writers. Sweep, sync, camera and composite writers read the mode under the shared lock. An agent check-in reads `Mode.current/0` without it (`LegacyWrites`).
- [ ] 3.2 Under the drained switch to `cutover`, seed `device_availability_legacy` from `is_available` before any reader switches. In `cutover`, legacy writers write only that table, computing against it, and the resolver suppresses all transition side effects.
- [ ] 3.3 The reconciliation job (`CutoverWorker`, phase `reconcile`):
  - re-resolves every device from its current ledger rows, evidence and vantage expectations under the device lock, through `Resolution.resolve_locked/2` (never copying shadow output), writing false where `is_available` is NULL, and stops if the mode leaves `cutover`;
  - refreshes the rollups once, still in `cutover`;
  - moves the mode to `authoritative` only when that pass finishes, and enqueues `announce` in the same transaction. Announce publishes the summary and, when transition events are on, `device.available` for devices whose legacy value was false and whose merged state is available. Announce stops unless the mode is still `authoritative`.
- [ ] 3.3a Rollback to `legacy`: the switch deletes waiting transition jobs and enqueues a paged restore of `is_available` from `device_availability_legacy`. The restore runs after the switch commits and stops unless the mode is still `legacy`; the mirror re-derives `availability_state`. Legacy publishers resume with the mode. A transition job already running publishes nothing once the mode is no longer `authoritative`.
- [ ] 3.4 Rollup migration: an `unknown` key and triggers that count by `availability_state`. The statement triggers keep their shape; migration `20261024120000` records why a `WHEN` clause cannot narrow them.
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
- [x] 3.8 web-ng:
  - the badge from state;
  - "up from N of M agents" and the partial-reachability marker;
  - the negative-control indicators;
  - an Unknown card;
  - the evidence section and the agent role labels on the device page;
  - the API JSON;
  - the MCP cookbook.
  - `elixir/web-ng/priv/static/openapi.json` is generated from the core Device Ash resource. This cutover edited that generated document in place (the merged availability read attributes and the `is_available` description) because regenerating it needs `mix`.
- [ ] 3.9 Lab-deployment proof, each check with an explicit failure branch:
  - order, count and badge agree for every device;
  - Armis agent-path candidate rows are byte-identical to stage a for the same ledger contents;
  - no per-device event burst at cutover;
  - WAL per hour is at or below the baseline.

### 3a. Automatic progression (decided 2026-10-25; design.md, Decision 10)

> Superseded by `simplify-merged-availability-rollout`: the progression, its readiness conditions, the mode control and its Helm pin are removed.

- [x] 3a.1 Migration: `availability_settings.mode_control` (default `auto`), `mode_control_pin`, `shadow_entered_at`, `shadow_resolved_at`, `readiness`, `readiness_checked_at`; a deployment already in `shadow` takes `shadow_entered_at` from `updated_at`. Helm `core.migrations.expectedVersion` bumped.
- [x] 3a.2 `ModeControl`: the three controls, the `SERVICERADAR_AVAILABILITY_MODE_CONTROL` pin (an invalid value holds), and `set/2`, which runs `Setting.set_mode_control` and enqueues a run. The action is refused while a pin is recorded.
- [x] 3a.3 `Readiness`: the five conditions, each one bounded query; `CaptureBackfillWorker.pending?/0` and `DivergenceReport.policy_violations/1` share their owners' predicates. `ShadowEntryWorker` records `shadow_resolved_at` after a full pass that started after the entry.
- [x] 3a.4 `ProgressionWorker` (cron every minute, `maintenance`, unique): records the pin and the readiness, takes one step through the existing switches, and re-enqueues a missing restore when the compatibility snapshot still differs instead of entering `shadow`. It records `availability_cutover_readiness` unhealthy when the conditions are unmet 24 hours after the entry, and records it healthy on a later run only when that check is already unhealthy and the stall no longer holds. Switches take `control:` and refuse a changed control; `Mode.enter_legacy/1` in `legacy` changes nothing, so a repeated rollback keeps the restore.
- [x] 3a.5 `Operator.switch/1` sets the matching control; `Operator.control/1`; `status/0` reports the control, the pin and the readiness. Both refuse while pinned.
- [x] 3a.6 Helm `core.availability.modeControl` (validated) as the env pin; the settings panel on Availability Sources (mode, control, readiness; read-only when pinned).
- [x] 3a.7 Runbook rewritten: nothing to do by default, with an operator appendix. CHANGELOG Unreleased entry.
- [ ] 3a.8 Tests (`availability_progression_integration_test.exs`, DB tier; `progression_worker_test.exs`, unit): legacy and zero-device installs reach `authoritative` unattended; each unmet condition blocks and is named; the 24-hour warning; `hold_legacy` and `hold_shadow` from `authoritative`; the pin; two concurrent runs switch once. Run in BazelCI Core Integration.
- [ ] 3a.9 First live upgrade from `shadow`: the progression enqueues the full pass the deployment never recorded, then cuts over when ready; verify with the runbook's checks.

## 4. Stage d: removal (gated on no Armis source left in `legacy`)

- [ ] 4.1 Delete the legacy writes from W1, W2 and W5-W11. Keep the compatibility table, the mode setting, the mirror trigger and the `metadata.sweep_*` keys intact through a rollback window of at least one release.
- [ ] 4.2 Remove `is_available` from the Device accept lists. Delete `:set_availability`, the unused `:available` read action and the unused `status_color` calc, or switch them to the state.
- [ ] 4.3 Delete `effective_availability/2`, `ServiceRadar.Core.ResultProcessor`, and the dead Go `service_registration.go` constructors.
- [ ] 4.4 Migration (additive, with a down migration): `availability_write_violations` and an `AFTER UPDATE OF is_available` trigger that only appends a violation row when the column changes in `cutover` or `authoritative` without a matching state change. It never restores or rejects a write (Q7). A static check fails the build when code outside the resolver writes `is_available`.
- [ ] 4.5 Rollback drill on the lab deployment: revert the stage-d release and confirm the stage-c writers resume against the retained objects.

## 4e. Stage e: cleanup (after the stage-d rollback window; the point of no easy return)

- [ ] 4e.1 Migration: strip the `metadata.sweep_*` keys in pages, and drop `device_availability_legacy`, the mirror trigger and the mode setting.

## 5. Tests (written with the implementation; the test-audit authoring gate applies)

Each contract has one owner-boundary test. No contract is replayed at another layer. Every fixture is invented: `192.0.2.0/24` addresses and `SITE01-` names.

- [x] 5.1 **Resolver owner** (pure, table-driven, unit tier). `resolve/3` over invented ledger and evidence sets. The one table covers:
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
- [x] 5.6 **Expiry job** (DB tier). An expired `self_report` re-resolves to unknown; an unexpired one is untouched. The expiry pass re-checks freshness under the device lock from current committed rows.
- [ ] 5.6c **Renewal vs expiry** (DB tier, real concurrent transactions). A validation scan renews an unchanged `up` ledger row just before its TTL ends while the expiry job resolves the same device from the older committed row; in both commit orders the device ends `available` after the next worker pass, and a steady renewal of a row fresher than half its TTL appends no log row.
- [ ] 5.6a **Invalidation** (DB tier). With `write_canonical_availability` off, two validation-scan failures (W18, unchanged code) re-resolve the device to `unavailable` before expiry; changing the pin and adding a negative-control expectation each re-resolve the device without new evidence; a steady fresh renewal through the real sweep upsert (`INSERT ... ON CONFLICT DO UPDATE`) appends no log row; and a ledger write that commits while the worker is resolving the same device (claim taken, inputs already read) leaves its log row unclaimed, so the next pass resolves the device from the newer result.
- [ ] 5.6b **Writer-vs-worker concurrency** (DB tier, real concurrent transactions). Each of these, run concurrently with the worker on the same devices in both interleavings (worker claims first; writer appends first), completes without a deadlock error, never waits on the invalidation log, and leaves the device resolved from the newest committed inputs: a sweep transaction that writes ledger rows and resolves inline; a MergeEngine merge that holds the device locks and reassigns ledger rows (W19); a validation scan (W18); and a pin change.
- [x] 5.7 **Merge** (DB tier, in the existing merge-engine suite). The survivor holds both devices' evidence and is re-resolved; ledger reassignment is unchanged.
  - Owned by `availability_shadow_integration_test.exs` (merge through `MergeEngine.merge_devices/3`), which also owns the stage-b parts of 5.2 (write-on-change against `xmin`), 5.6a (validation scans, a pin change and a new negative control re-resolve through the log) and 5.6b (a merge holding both devices never waits on an inline evidence write; real concurrent transactions). The outbox and transition parts of 5.2 and the remaining 5.6a-5.6c interleavings belong to stage c.
- [ ] 5.8 **Cutover and rollback** (DB tier). During `cutover`, ingestion plus reconciliation publish no per-device events, and a legacy writer started before the switch cannot land after it. One summary event is published. Down evidence ingested during `cutover` is not overwritten by reconciliation from an older shadow `available`. After a rollback to `legacy`, `is_available` equals the compatibility value and `availability_state` its projection.
- [ ] 5.9 **SRQL** (Rust; extends the existing device query tables):
  - default order rank;
  - `availability:unknown`;
  - an unknown device returned with its last `is_available` boolean;
  - `agent_reachability:partial`;
  - `availability_policy:violation`;
  - unchanged `unavailable_from_agent`;
  - the summary `unknown` count.
- [x] 5.10 **web-ng** (LiveView, at the badge and row component boundary):
  - the three states;
  - "N of M agents" with the partial marker;
  - the negative-control indicators.
- [ ] 5.11 **Write-violation audit** (DB tier). In `authoritative`, a direct `UPDATE ... SET is_available` commits as written (the trigger neither restores nor rejects it) and appends one violation row; a resolver write appends none. The static check fails on an invented writer outside the resolver.

## 6. Validation

- [ ] 6.1 `openspec validate add-merged-device-availability --strict`
- [ ] 6.2 Per stage:
  - focused tests;
  - `mix format` and `credo`;
  - `cargo fmt` and `clippy` on the touched crates;
  - the repository gate through no-mistakes.
