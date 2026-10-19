## 0. Preconditions

- [ ] 0.1 Archive `add-per-agent-availability` so that its device-inventory requirements are in `specs/` before this change archives
- [ ] 0.2 Get the user's decisions on the design.md Open Questions, especially Q2 (reading the vantage `expected` value), Q3 (how unknown projects), Q4 (whether a negative-control reach counts as liveness) and Q12 (the Armis default)
- [ ] 0.3 Fix the NULL-handling readers marked "fix" in design.md before stage c:
  - SRQL JSON `unwrap_or(false)`;
  - grouped `NotEq` including NULL;
  - `basic_summaries.ex` counting NULL as unavailable;
  - `device_tab_runtime.ex:201` turning false into nil.

## 1. Stage a: capture (mode `legacy`, no behavior change)

- [ ] 1.1 Migration:
  - `device_agent_availability.consecutive_down` (additive, default 0);
  - `device_availability_evidence`, `device_vantage_expectations` and `device_availability_shadow`;
  - the `ocsf_devices.availability_*` columns;
  - the Armis source attribute `northbound_availability_semantics`, with existing sources set to `legacy`.
- [ ] 1.2 Source registration descriptors `{source_kind, authority_class, default_ttl, min_ttl, max_ttl}`, and Ash resources for the new tables.
- [ ] 1.3 The sweep ledger upsert maintains `consecutive_down` in the same statement. No other ledger change; the ledger is never pruned or rewritten by availability code.
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
- [ ] 1.6 The composite evaluation pass materializes vantage expectations, write-on-change.
- [ ] 1.7 Backfill:
  - `consecutive_down` from `metadata.sweep_consecutive_failures`, capped;
  - vantage expectations;
  - `operator_policy` evidence from composite verdicts.
- [ ] 1.8 Lab-deployment proof: `is_available`, the badges and the Armis candidate rows match the previous release for a full day. Record WAL bytes per hour as the baseline.

## 2. Stage b: shadow (mode `shadow`)

- [ ] 2.1 `Availability.Resolver.resolve/3`, a pure function implementing Decisions 3, 5, 6 and 12.
- [ ] 2.2 Transactional resolution: uid-ordered locks, batches of at most 500, a shadow write on change only.
- [ ] 2.3 The expiry job, paged.
- [ ] 2.4 Re-resolution on merge, unmerge and restore, with evidence moving on merge (Decision 11). Ledger reassignment unchanged.
- [ ] 2.5 Divergence report:
  - counts by legacy value, legacy badge, shadow state, `source_kind` and `authority_class`;
  - devices that would become unknown;
  - policy violations;
  - invalid pins (a pinned agent that is a negative control);
  - per-source Armis canonical push changes;
  - sample uids.
- [ ] 2.6 Run on demo and the lab deployment, including the Wi-Fi AP split, and review with the user. This is the cutover gate.

## 3. Stage c: cutover (`cutover` then `authoritative`)

- [ ] 3.1 The mode switch takes an advisory lock that drains in-flight writers; writers read the mode under the shared lock.
- [ ] 3.2 In `cutover`, legacy writers write only `device_availability_legacy` (create the table), and the resolver suppresses all transition side effects.
- [ ] 3.3 The reconciliation job:
  - applies the shadow decisions;
  - refreshes the rollups once;
  - reconciles stateful alerts;
  - emits one summary event;
  - moves the mode to `authoritative` only when it has finished.
- [ ] 3.4 Rollup migration: an `unknown` key, the trigger counting by state, and a narrowed `WHEN`.
- [ ] 3.5 Resolver-emitted transitions go through the outbox. Display-only changes broadcast a UI invalidation only. `state_events.ex` stops publishing `is_available`.
- [ ] 3.6 Armis runner:
  - the canonical path reads `device_availability_legacy` for `legacy` sources, and the state (withholding unknown) for `merged` sources;
  - the source settings preview and the adopt action;
  - the agent path is untouched.
- [ ] 3.7 SRQL:
  - the `availability`, `availability_source`, `availability_class`, `agent_reachability` and `availability_policy` fields, plus `agents_up` and `agents_total`;
  - default order by availability rank;
  - the summary `unknown` count;
  - NULL JSON output.
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

- [ ] 4.1 Delete the legacy column writes from W1, W2 and W5-W11, the compatibility table and the mode setting.
- [ ] 4.2 Remove `is_available` from the Device accept lists. Delete `:set_availability`, the unused `:available` read action and the unused `status_color` calc, or switch them to the state.
- [ ] 4.3 Delete `effective_availability/2`, `ServiceRadar.Core.ResultProcessor`, and the dead Go `service_registration.go` constructors.
- [ ] 4.4 Migration: strip the `metadata.sweep_*` keys in pages, and add the backstop trigger and violations table (per Q7).
- [ ] 4.5 Add the plugin manifest `availability_authority` for proxmox, starlink and opentext-nom. Settle awx per Q9.

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
  - negative controls, both a verified block and a violation;
  - an invalid pin on a negative control.
- [ ] 5.2 **Transactional owner** (DB tier, `srql-fixtures` scratch DB). `record_evidence/2` and `resolve_devices/2` against real rows:
  - two sources do not overwrite each other;
  - the device row is untouched when nothing changes (assert on `xmin`);
  - a conflict-only change updates the row without an outbox transition;
  - a transition writes one outbox row, and a rollback writes none.
- [ ] 5.3 **Ledger losslessness** (DB tier). After resolution and after the expiry job, every agent's row (up, down and stale) is unchanged in value and `checked_at`.
- [ ] 5.4 **Sweep ingestion regression** (DB tier). Must fail on today's code. A device with controller `up` evidence and repeated sweep failures keeps a stable state, and its row is not rewritten per sweep.
- [ ] 5.5 **Armis agent path** (DB tier, in the existing runner suite). `candidates_query/1` with an agent selected returns identical rows whether or not availability resolution has run, including for a should-be-blocked agent. Canonical `legacy` reads the compatibility table; canonical `merged` withholds unknown.
- [ ] 5.6 **Expiry job** (DB tier). An expired `self_report` re-resolves to unknown; an unexpired one is untouched.
- [ ] 5.7 **Merge** (DB tier, in the existing merge-engine suite). The survivor holds both devices' evidence and is re-resolved; ledger reassignment is unchanged.
- [ ] 5.8 **Cutover** (DB tier). During `cutover`, ingestion plus reconciliation publish no per-device events, and a legacy writer started before the switch cannot land after it. One summary event is published.
- [ ] 5.9 **SRQL** (Rust; extends the existing device query tables):
  - default order rank;
  - `availability:unknown`;
  - `is_available:false` excluding NULL in both list and grouped queries;
  - JSON `null`;
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
