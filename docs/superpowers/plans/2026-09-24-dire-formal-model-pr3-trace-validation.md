# DIRE Formal Model PR 3: Trace Validation (Resolution) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Couple `formal/dire/DireResolution.tla` to the real Elixir code. Integration tests drive
real ingestion paths through scenarios built from model actions, record the full model state
after every step, and commit the resulting traces. `tlc_test`s then check that each trace is a
behavior of the model with the switches matching today's code. Wherever code and model disagree,
the code decides: either the model is corrected (citing the function) or a new defect is
recorded (a switch, a witness, an issue).

**Architecture:** This follows the pattern AGENTS.md prescribes for generated artifacts: a
committed copy, a check that fails when it is stale, and a way to rewrite it.

- `ServiceRadar.DireTrace` (test support) records each step. It reads observable state from the
  database: records, tombstones, merge redirects, identifier owners, device IPs, confirmed
  aliases, interface-MAC claims, and revision changes. The harness itself supplies ground truth
  (DHCP leases, and which physical device an observation came from), the step's action, and the
  identity decisions it saw as telemetry (decided) and as persisted rows (recorded).
- The integration test compares the recorded trace with the committed
  `formal/dire/traces/<name>.tla` byte for byte. With `DIRE_TRACE_WRITE=1` (a local scratch-DB
  run) it rewrites the file instead.
- `formal/dire/DireResolutionTrace.tla` pins every model variable to the trace at each step.
  Each trace has a `tlc_test` that expects `violation:TraceIncomplete`: TLC reaching the last
  trace state is the proof that the whole trace was matched. A trace that diverges deadlocks
  early, TLC reports no error, and the test fails.
- The Elixir lanes never run Java. TLC stays in `make test`, where it already runs hermetically.

**Tech Stack:** ExUnit (DataCase, `:integration`), TLA+/TLC via `//build/tla:tlc.bzl`.

**Spec:** `openspec/changes/add-dire-formal-model` design D7 (trace validation, amended by
Task 6 below) and `update-dire-strong-identity-goal` (the requirements).

**Scope:** the resolution model only. Lifecycle traces are PR 4, planned after this merges.
Black-box tests cannot interleave a merge inside one `SyncIngestor.ingest_updates/2` call, so
the fence switch stays model-only until the fence is enforced (#4618). PR 4 says so explicitly.

## Global Constraints

- Branch `feat/dire-trace-validation` in treehouse slot 27, cut from `origin/staging` after #4627.
- Commit as `git -c user.email=mfreeman@carverauto.dev -c user.name="Michael Freeman" commit`,
  with the Co-Authored-By trailer.
- Test data is synthetic only:
  - MACs `00:00:5E:00:53:xx` (IANA documentation; universal-bit form) and `02:00:5E:00:53:xx`
    (the locally-administered form).
  - Addresses from the existing test helpers' CGNAT ranges.
  - Armis ids from `System.unique_integer`, mapped to model constants in first-seen order.
- The DB runs use the scratchpad `dbctl.sh` flow on `srql-fixtures` (authorized). Drop the scratch
  database at the end, then re-query to confirm it is gone.
- New test files get their `INTEGRATION_SOURCE_DISPOSITIONS.tsv` row and, if serial,
  their `build/integration_test_dispositions.bzl` entry. Verify with
  `python3 -m unittest build/contracts/ci_heavy_gate_contract_test.py`.
- Changes to production code are out of scope. A defect found here gets a switch, a witness, a
  trace and an issue. It is not fixed in this PR.
- PR through `no-mistakes`.

## Known fidelity gaps to resolve (found while planning, from code reads)

1. **ARP-style observations** go through `DiscoveryIngestor`, the census decoder,
   `SyncIngestorQueue`, `SyncIngestor` and `BatchResolver`, not `Resolver`/`AliasGuard`. A
   census update is an observer source with no non-MAC identifier, so `Sync.Aliases` never
   merges on it. The model's `ArpObserve` runs `AliasGuard`, which is wrong.
2. **The mapper resolves by address first** (`MapperResultsIngestor.resolve_device_ids/2`: a
   live device with that IP). It calls DIRE (`Resolver` plus `AliasGuard`) only for an address
   with no live holder, and it registers the polled device's interface MACs as `:interface_mac`
   claims on whichever record it resolved to. The model's `DiscoveryObserve` resolves by MAC and
   has no interface claims.
3. **Interface claims feed `AliasGuard.same_chassis?/5`,** which lifts the distinct-MAC veto. A
   claim created by an address-first attach could therefore unlock a real merge later.
4. **An alias becomes confirmed only after 3 sightings** (`AliasEvents`,
   `:identity_alias_confirm_threshold`). The model confirms nondeterministically, which is
   compatible, but the traces must drive 3 sightings.

Candidate new defect, to be confirmed or refuted by trace R6: after DHCP churn, the mapper
attaches device B's interface table to device A's stale record (address-as-identity). If
confirmed, it becomes switch `mapper_attach_by_address` with a property that interface claims on a record come only
from its own physical device.

## Review Focus

1. **A trace passing because a variable is left unpinned.** Every model variable is pinned at
   every step; Task 2's self-test tampers one field in each variable and requires rejection.
2. **Nondeterministic trace content** (uids, ordering). Every real uid and identifier is mapped
   to a model name in first-seen order, and sets are sorted before printing. Task 3 runs each
   trace twice and requires identical bytes.
3. **Recording a state the model cannot represent** (extra identifier types, extra records).
   The recorder raises and names what it cannot map, instead of dropping it.
4. **Telemetry from concurrent tests polluting decisions.** The trace tests run in a serial lane
   (global telemetry handler), with a SERIAL_REASONS entry.
5. **A trace committed from a buggy recorder.** Each trace is also reviewed by hand against the
   scenario's expected steps, which are listed in the test.

---

### Task 1: Model fidelity corrections (DireResolution.tla)

- [ ] Rewrite `ArpObserve` as the census path: `SyncIngestor`/`BatchResolver` resolution, and no
      alias merge, because an observer source with no non-MAC identifier is excluded from
      `Sync.Aliases`.
- [ ] Rewrite `DiscoveryObserve` as the mapper:
      - Resolve by address first. A live record with `recIp = p` takes the observation and gains
        the reported MACs as interface claims.
      - Otherwise run the `Resolver` path: strong match, `AliasGuard`, fallback create.
- [ ] Add `ifClaims: [Recs -> SUBSET MacIds]` and make `DistinctMacs`' veto honor
      `same_chassis?`. A claim of the other record's MAC lifts the veto.
- [ ] Add the property `NoFalseInterfaceClaim`: every MAC claimed on a live record belongs to a
      physical device in its `phys`, or the record is address-only.
- [ ] Re-run every existing `resolution_*` configuration. Goal configurations must still pass;
      for a witness that no longer reproduces, re-derive it from the corrected model and read its
      trace against the code before accepting it.

### Task 2: Trace spec and its self-test

- [ ] `formal/dire/DireResolutionTrace.tla`:
      - `EXTENDS DireResolution, Sequences, TLC`; `CONSTANT TraceLog`; `VARIABLE ti`.
      - `TraceInit`: `ti = 1`, with every variable equal to `TraceLog[1]`. It also requires
        `Init`, because scenarios start from an empty world.
      - `TraceNext`: `ti < Len(TraceLog)`, `ti' = ti + 1`, `Next`, and every primed variable
        equal to `TraceLog[ti + 1]`.
      - `TraceIncomplete == ti < Len(TraceLog)`.
- [ ] `formal/dire/traces/selftest_*.tla`: one hand-written three-step trace that must be matched,
      and variants that each tamper one variable (`ipAt`, `created`, `into`, `owner`, `recIp`,
      `alias`, `ifClaims`, `phys`, `act`). The tampered variants must not be matched (expect
      `pass`, meaning TLC never reaches the end).

### Task 3: Recorder (`test/support/dire_trace.ex`)

- [ ] World declaration: physical devices, interfaces, MACs, addresses, Armis ids, all mapped to
      model constants.
- [ ] Steps:
      - `lease/3` (ghost).
      - `armis/3`, `discovery/3`, `arp/3`, `sweep/3`. Each calls the real entry point:
        - Armis: `SyncIngestor.ingest_updates/2`, with Armis identity in `metadata`.
        - Discovery: `MapperResultsIngestor.ingest_interfaces/2`.
        - ARP: `SyncIngestor.ingest_updates/2` with the census shape.
        - Sweep: `SweepResultsIngestor.ingest_results/3`.
      - Each step captures identity telemetry, then snapshots.
- [ ] Snapshot:
      - records named by model seed in first-seen order;
      - `into` from `merge_audit`;
      - `owner` from `device_identifiers`, with `armis_device_id` and `integration_id` both
        mapped to the device's model source id;
      - `recIp` from `ocsf_devices.ip`;
      - `alias` from confirmed or updated alias states;
      - `ifClaims` from `InterfaceMacs`;
      - `phys` from ground truth plus merges;
      - `act` from the step plus telemetry and `source_identity_conflicts` rows.
- [ ] `to_tla/2` and `to_cfg/2`, emitting a trace module, its environment definitions and the
      current-code `Bugs`. Output is deterministic: sorted sets, stable names.
- [ ] `assert_golden!/2`: compare with `../../formal/dire/traces/<name>.{tla,cfg}`, or write them
      when `DIRE_TRACE_WRITE=1`.

### Task 4: Scenario traces (`test/serviceradar/inventory/dire_resolution_trace_test.exs`)

Each test lists its expected steps in a comment:

- **R1** `armis_dhcp` (#4609, fixed): discovery of A (m1) at p1, sighted three times; A leaves
  p1; Armis device B (b, m2) leases p1 and is synced. No merge; A's alias goes stale.
- **R2** `alias_unknown_mac` (#4610): Armis A (no MAC) at p2, three sightings. A moves, and its
  Armis sync updates the IP. B (m2) is discovered at p3, then DHCP moves B to p2, which has no
  live holder, so the mapper goes through DIRE, `AliasGuard` and a strong match on m2. A is
  merged into B.
- **R3** `src_attach_shared_mac` (#4611): Armis A (a1, m1), then Armis B (a2, m1).
- **R4** `router_mac_only` (#4612): ARP on x1 (m1, p1) and x2 (m2, p2); then the mapper reports m1
  and m2 at p1.
- **R5** `silent_policy_block` (#4613): two records matched by a MAC-only set; the MergePolicy
  refusal reaches telemetry only.
- **R6** `mapper_stale_address` (candidate): discovery of A (m1) at p1; A leaves; B (m2) leases
  p1; the mapper polls p1.

- [ ] Run on the scratch DB with `DIRE_TRACE_WRITE=1`, then again without it (byte-identical).
- [ ] For each trace, read it against the listed steps before committing.

### Task 5: Wire the checks

- [ ] `formal/dire/BUILD.bazel`: add a `traces` filegroup and one `tlc_test` per trace plus the
      self-tests.
- [ ] `elixir/serviceradar_core/BUILD.bazel`: add `//formal/dire:traces` to
      `INTEGRATION_RUNTIME_DATA`.
- [ ] Add the disposition rows for the new test file, with a SERIAL_REASONS reason (global
      telemetry handler).
- [ ] Run the contract test, then
      `bazel test --config=remote //formal/dire/... //build/contracts/...` and `make test`.

### Task 6: Findings and docs

- [ ] For every trace TLC rejects, decide whether the model or the code is wrong, from the code:
      - Model wrong: fix the model and cite the function.
      - Code wrong: add a switch, a witness, keep the trace, and file an issue.
- [ ] Update `formal/dire/README.md` (trace workflow, how to regenerate) and `add-dire-formal-model`
      design D7 (the committed-trace architecture replaces running TLC inside the Elixir lanes),
      and tick tasks 3.x.
- [ ] Drop the scratch database, then re-query to confirm it is gone. PR via `no-mistakes`.

## Execution notes

- **Order.** The recorder and traces (Tasks 3-4) ran before the model corrections (Task 1), so
  that the corrections were driven by what the real code emitted rather than by code reading.
- **Scenarios.**
  - R5 (a silent MergePolicy block) was dropped as a separate trace: no model observer reaches a
    MAC-only conflict on the real mapper path.
  - An agent-path trace (`agent_alias_unknown_mac`) was added instead, because agent check-in is
    the real route into AliasGuard. It reproduced #4610 as a merge of the Armis device into the
    agent's record.
- **Confirmed by trace against the real code.** #4609 fixed; #4610 through the agent path; #4611;
  and two new defects:
  - `mapper_resolves_by_address`: the mapper attaches a polled device's interface table by
    address, or by a stale alias.
  - `stale_holder_keeps_address`: a fresh source-authoritative write loses the address to a stale
    holder.
- **Corrections to the model.**
  - ARP goes through census and sync, with no alias merge.
  - The mapper resolves by address, then by alias, then through DIRE.
  - Agent check-in goes through the Resolver and AliasGuard.
  - The active-IP collision rule: adopt a provisional seed, drop the address, or record the
    conflict.
  - New state: interface claims and agent ids.
  - New properties: `NoFalseInterfaceClaim` and `ObservedAddressHeld`.
- **Sizing.** A `VIEW` without the `act` history keeps the fingerprint down, and each Armis
  environment carries only the observers it tests. Every configuration finishes in 25 s or less
  on a workstation.
- **Verification.**
  - 44 `//formal/dire` targets pass on RBE: 6 real traces matched, 9 tampered variants rejected.
  - The recorded traces are byte-identical across runs.
  - The contract test passes, Credo is clean, and the scratch database was dropped.
