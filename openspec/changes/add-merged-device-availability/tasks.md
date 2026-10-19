## 0. Preconditions

- [ ] 0.1 Archive `add-per-agent-availability` so that its device-inventory requirements are in `specs/` before this change archives
- [ ] 0.2 Get the user's decisions on the design.md Open Questions (cross-class conflict, unknown projection, never-evidenced devices, composite precedence, event gating, backstop trigger, plugin class location, awx)
- [ ] 0.3 Fix the NULL-handling readers marked "fix" in design.md before stage c: SRQL JSON `unwrap_or(false)`, grouped `NotEq` NULL inclusion, `basic_summaries.ex` NULL-as-unavailable, `device_tab_runtime.ex:201` false-to-nil, Armis northbound runner `COALESCE(is_available,false)`

## 1. Stage a: evidence capture (mode `legacy`, no behavior change)

- [ ] 1.1 Migration: `platform.device_availability_evidence` (PK `(device_uid, source_kind, source_instance, reporter_agent_id)`, indexes on `expires_at` and `device_uid`), `ocsf_devices.availability_state|availability_decided_by|availability_changed_at|availability_conflict`, and `device_availability_shadow`
- [ ] 1.2 Ash resources for the evidence and shadow tables (`migrate?` per repo conventions); source registration descriptors with `{source_kind, authority_class, default_ttl, min_ttl, max_ttl}`
- [ ] 1.3 `ServiceRadar.Inventory.Availability.record_evidence/2` with write-on-change and lease renewal; resolution disabled in `legacy`
- [ ] 1.4 Submit evidence from every writer in the design's inventory:
  - sweep (W1, W2 and W4, including reporter eligibility);
  - Wi-Fi map (W5, no evidence for a missing status);
  - sync path (W6, per source registration);
  - plugin discovery (W7, W13);
  - hypervisor (W8);
  - camera (W9);
  - agent liveness (W10);
  - composite checks (W11);
  - mapper (W12);
  - validation scans (W18, explicit eligibility).
- [ ] 1.5 Backfill: copy fresh `device_agent_availability` rows into the evidence table as `active_probe`, and copy composite verdicts for checks with `write_canonical_availability`
- [ ] 1.6 Lab-deployment proof: for a full day, `is_available` values and badge values match the previous release; record evidence write rate and WAL bytes per hour as the baseline

## 2. Stage b: shadow resolution and divergence report (mode `shadow`)

- [ ] 2.1 `Availability.Resolver.resolve/3`, a pure function implementing Decisions 3-6
- [ ] 2.2 Transactional resolution (uid-ordered `FOR NO KEY UPDATE`, batches of at most 500) writing `device_availability_shadow` on change only
- [ ] 2.3 Expiry job (Oban, paged by `expires_at`) re-resolving devices with expired evidence
- [ ] 2.4 Evidence moves on merge, and re-resolution on merge, unmerge and restore (Decision 11)
- [ ] 2.5 Divergence report: an admin page plus a periodic summary log line. Counts by legacy value, legacy badge, shadow state, deciding source kind and authority class; devices that would become unknown; up to 20 sample uids per cell
- [ ] 2.6 Run on demo and the lab deployment; review the report with the user, including the Wi-Fi access point split (controller up, no status, static import); this is the cutover gate

## 3. Stage c: cutover (mode `authoritative`)

- [ ] 3.1 Migration: rollup tables gain an `unknown` key; the rollup trigger counts by `availability_state` and fires only when its inputs change
- [ ] 3.2 Reconciliation job applying the shadow decisions with per-device side effects suppressed, one summary event, a single rollup refresh, and reconciliation of stateful alerts
- [ ] 3.3 Resolver-emitted transitions: `device.available` and `device.unavailable` with provenance attributes through the outbox; `signals.state.ocsf_devices` `is_available` and `availability_state`; DevicePubSub on change only. Remove `is_available` publishing from `state_events.ex`
- [ ] 3.4 Legacy writers skip their column writes in `authoritative`, and `device_writes` stops setting `is_available` in `on_conflict`
- [ ] 3.5 SRQL: `availability`, `availability_source` and `availability_class` fields; default order by availability rank; inventory summary `unknown`; `is_available` NULL output
- [ ] 3.6 web-ng: badge, stat cards and links read the canonical state; Unknown card; conflict marker and tooltip; evidence table on the device page; API JSON and `openapi.json` add `availability_state`; MCP cookbook examples
- [ ] 3.7 Armis northbound: preview run before the first post-cutover push; confirm unknown is withheld
- [ ] 3.8 Lab-deployment proof:
  - list order, Available count and badges agree for every device (a query comparing the three, with an explicit failure branch);
  - WAL bytes per hour no higher than the stage-a baseline;
  - no per-device event burst at cutover.

## 4. Stage d: removal

- [ ] 4.1 Delete the legacy column writes from W1, W2, W5-W11 and the mode setting
- [ ] 4.2 Remove `is_available` from the `Device` accept lists; delete `:set_availability`, the unused `:available` read action and the `status_color` calc (or move them to the state)
- [ ] 4.3 Delete `DeviceLive.IndexData.Availability.effective_availability/2`, the dead `ServiceRadar.Core.ResultProcessor` and the dead Go `service_registration.go` constructors
- [ ] 4.4 Migration: strip `metadata.sweep_consecutive_failures` and `sweep_last_available_at` in pages; add the backstop trigger and `device_availability_write_violations` (per the Open Question 6 decision)
- [ ] 4.5 Plugins: manifest `availability_authority` for proxmox, starlink and opentext-nom; the awx decision per Open Question 8

## 5. Tests (written with the implementation; the test-audit authoring gate applies)

Each test names its single owner boundary. None replays the same contract at another layer.

- [ ] 5.1 **Resolver owner (pure, table-driven, unit tier)**: `Availability.Resolver.resolve/3` over invented evidence sets. One table covers class ranking, available-wins within a class, the pinned-agent exclusion, ineligible reporters, hysteresis below and at the threshold, immediate recovery, expiry to unknown, and a pending down keeping the prior state. This protects the precedence contract. A credible regression is a reordered class or a pin applied across classes. No other test restates these cases.
- [ ] 5.2 **Transactional owner (DB tier, `srql-fixtures` scratch DB)**: `record_evidence/2` against real rows proves:
  - two sources do not overwrite each other;
  - the device row is untouched when the decision is unchanged (assert on `xmin` or `modified_time`, not a mock);
  - a transition writes exactly one outbox row, and a rollback writes none.
- [ ] 5.3 **Sweep ingestion boundary (DB tier)**: one regression that fails on today's code. A device with controller `up` evidence and repeated sweep failures keeps a stable state, and its row is not rewritten per sweep. Today the column flips. Fixtures are invented: `192.0.2.0/24` addresses and `SITE01-` names.
- [ ] 5.4 **Expiry job (DB tier)**: an expired `self_report` re-resolves to unknown, and an unexpired one is untouched.
- [ ] 5.5 **Merge (DB tier, in the existing merge-engine suite)**: the fresher evidence survives a collision, and the survivor is re-resolved.
- [ ] 5.6 **Reconciliation (DB tier)**: cutover applies the shadow states and publishes no per-device events, only one summary event.
- [ ] 5.7 **SRQL (Rust, translation plus the fixture DB)**: default order rank, `availability:unknown`, `is_available:false` excluding NULL in list and grouped stats, JSON `null` output, and inventory-summary `unknown`. These extend the existing device query tables rather than adding parallel files.
- [ ] 5.8 **web-ng (LiveView)**: the badge renders from `availability_state` for each of the three states plus conflict. One test, at the badge component boundary.
- [ ] 5.9 **Armis northbound runner (DB tier)**: an unknown device is withheld, not exported.
- [ ] 5.10 **Backstop trigger (DB tier)**: a direct `UPDATE ... SET is_available` outside the resolver leaves the value unchanged and appends a violation row.

## 6. Validation

- [ ] 6.1 `openspec validate add-merged-device-availability --strict`
- [ ] 6.2 Per stage: run focused tests, `mix format`, `credo`, `cargo fmt`/`clippy` on touched crates, and the repository gate through no-mistakes
