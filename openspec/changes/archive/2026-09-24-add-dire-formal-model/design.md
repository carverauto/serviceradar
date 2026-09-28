# Design: a formal model of the DIRE device lifecycle

## Context

DIRE is spread across `elixir/serviceradar_core/lib/serviceradar/inventory/identity/`
(`merge_engine.ex`, `resolver.ex`, `batch_resolver.ex`, `registrar.ex`, `alias_guard.ex`,
`duplicate_sweep.ex`, `fence.ex`), the `Device` resource's lifecycle actions, the raw
upsert in `inventory/sync/device_writes.ex`, the sweep processors, and the alias state
machine in `identity/device_alias_state.ex`. Lifecycle state is not held in one place:

- A tombstone is `deleted_at`/`deleted_by`/`deleted_reason` on `ocsf_devices`.
- There is no merged-into column. "Where did this uid go" is derived from `merge_audit`: the
  latest row for `from_device_id` whose reason is not `unmerge`.
- `identity_revision` is bumped by `BumpIdentityRevision` and by raw SQL at a handful of
  remediation sites.
- Identifier ownership is `device_identifiers`, unique on
  `(identifier_type, identifier_value, partition)`.
- Provisional devices are a metadata marker, not a column.

Several writers can clear a tombstone, and they disagree about whether that bumps the
revision. That is the kind of property a model checker is for.

## Goals

- A bounded TLA+ model of the lifecycle that TLC checks in about one to two minutes.
- Each known defect is an executable, isolated counterexample.
- The intended design (no defects) is checked before any fix is written.
- The model is tied to the Elixir code by validating traces the real code produces, so a
  code change that the model does not reflect fails a test.
- Everything runs as Bazel tests; no scripts.

## Decisions

### D1. Model the code as it is, not as intended

A model of the intended design passes and teaches nothing. Each action is written from the
code path it names, including its defects, and cites the function (for example
`CommitWork` -> `DeviceWrites` `on_conflict`). Reviewers check the model against the source
action by action.

### D2. Intended behavior comes from the goal requirements

The first draft judged "intended" behavior from the code and from the legacy DIRE specs. Those
specs contradict each other, so a model grounded on them would check that DIRE stays broken.
Intended behavior now comes from `update-dire-strong-identity-goal`: one canonical device
record per physical device, whatever its address; identity from strong identifiers; an address
is evidence only. Each model property maps to one of those requirements.

### D3. Known defects are switches, confirmed in code

`CONSTANT Bugs` in each model names the defective branches. An action takes its defective
branch only when its switch is on. A switch is added only after a TLC counterexample for it has
been read against the Elixir code. There were 12 switches at first: 5 in the resolution model and
7 in the lifecycle model. A fixed defect loses its switch. `formal/dire/README.md` lists each
remaining switch with its code path and witness property, and each fixed one.

Four kinds of configuration:

- `goal`: no switches. Every property holds.
- `witness_<switch>`: one switch, or a named pair when two defects only appear together.
  TLC must report exactly the named property.
- `lifecycle_current`: every lifecycle switch on. The invariants that hold even for today's
  code.
- `vacuity`: the goal must still merge (a router's interfaces) and converge (Armis with
  network discovery), and it must still record a decision (a shared-MAC override). A goal
  model that never merges, or never decides, would pass every safety property.

### D4. Two models

**`DireResolution.tla`: resolution against physical ground truth.**

- The world: physical devices own interfaces, and each interface has a true MAC (hardware or
  randomized) and leases an address. DHCP moves addresses between interfaces.
- Observers report what they would really see: Armis (its id, and MACs when Armis reports
  them), network discovery (every interface MAC), ARP-style observation (one MAC and its
  address), and sweep (the address).
- Resolution follows `Resolver.do_resolve_device_id/2`, the sync ingestor's order (devices,
  then identifiers, then `Sync.Aliases`), `AliasGuard` and `SourceAuthorityGuard`.
- A ghost variable, `phys`, records which physical devices built each record. A false merge is
  therefore the invariant "one record describes two devices".
- Environments stand for real situations: Armis with and without MACs, Armis mixed with network
  discovery, a multi-interface router, randomized-MAC phones, and two Armis devices sharing a
  MAC.
- Properties:
  - `NoFalseMerge`
  - `DistinctSourceIdsNeverMerge`
  - `EvidenceConverges`: once identifiers are reported together, their owners are one record,
    unless two hold different source-authoritative ids.
  - `NoSilentDecision`
  - `AddressNeverMerges`: no merge is caused by address or IP-alias evidence.

**`DireLifecycle.tla`: merge, unmerge, soft delete, revival (upsert, sweep, gateway sync),
purge, and the fence.**

Two abstractions keep it checkable without losing a property:

- `identity_revision` is not stored. The fence only asks whether a revision moved after a pin,
  and the bump property only asks whether a revival moved it. So each step records the uids it
  bumped, and each in-flight item carries a `stale` flag.
- Time is a `recent` flag on `merge_audit` rows. The cooldown only asks whether a pair merged
  within the window.

Properties:

- `UniqueLiveIp`
- `MergedNeverOwnsIdentifiers`
- `MergeGraphAcyclic`
- `MergedRedirectsSomewhere`
- `NoStaleRedirect`
- `NoZombieRevival`
- `NoPurgedResurrection`
- `RevivalBumpsRevision`
- `UnmergeRestoresExactly`
- `NoStaleCommit`

The alias state machine is not modeled in the lifecycle model. Alias-driven merges are the
resolution model's subject.

Bounds are per configuration and live in the `.cfg` files. Every configuration finishes within
a `medium` test on the RBE executors, and the slowest takes about 40 seconds.

### D5. Assumptions (Lean candidates)

These are abstract predicates in the model, not proven:

- `MergePolicy.merge_allowed_for_matches?/1`: which evidence sets permit a merge.
- MAC normalization and locally-administered classification (`Identity.Mac`).
- Canonical survivor selection (`DuplicateSweep.choose_canonical_device_id/2`).
- Duplicate-component grouping (`DuplicateSweep.classify_duplicate_components/1`).

The model lets TLC choose any outcome these predicates permit. If a counterexample depends on
one of them, that function is the first candidate for a Lean 4 proof. Until then they are
covered by property tests against the Elixir functions, not by this change.

### D6. Bazel wiring

- `tla2tools.jar` is an `http_file` in `MODULE.bazel` with a pinned sha256.
- `rules_java` supplies the remote JDK; `java_binary(name = "tlc", main_class = "tlc2.TLC")`
  gives a TLC that does not depend on the host Java, on RBE or under `TestRunner=local`.
- `//build/tla:tlc.bzl` defines
  `tlc_test(name, spec, cfg, deps, expect = "pass" | "violation:<Property>")`, backed by a
  `py_test` driver. The driver decides on TLC's exit status and on the name of the violated
  property, parsed from the exact line TLC prints (copied from a real run, not guessed).
  `expect = "violation:X"` fails if TLC passes and fails if TLC reports a different
  property.
- A self-test spec under `//build/tla/selftest` has one passing and one deliberately
  violating configuration, proving the driver can fail in both directions before anything
  depends on it.

### D7. Trace validation

A model the code can drift away from verifies nothing. Trace validation is the coupling.

- `test/support/dire_trace.ex` (`ServiceRadar.DireTrace`) drives the real ingestion entry
  points step by step inside a synthetic physical world: `SyncIngestor` for Armis and census,
  `MapperResultsIngestor` for SNMP discovery, and `AgentGatewaySync` for agent check-ins.
  After every step it records the full model state:
  - **Database state:** records, merge redirects, identifier owners, addresses, confirmed
    aliases, interface-MAC claims.
  - **Ground truth only the harness knows:** DHCP leases, and which physical device each
    observation came from. The database cannot record this, because in production nothing
    knows it.
  - **Decisions:** the ones the code made (telemetry) and the ones it recorded (persisted
    rows).
- Real uids and identifiers map to model names by seed, in first-seen order. Output is
  deterministic: a second run reproduces every trace byte for byte. Anything the recorder
  cannot map raises instead of being dropped.
- **Traces are committed artifacts** (`formal/dire/traces`), following the AGENTS.md pattern
  for generated files: a committed copy, a check that fails when it is stale, and a rewrite mode.
  - The integration test compares each freshly recorded trace with its committed copy.
    `DIRE_TRACE_WRITE=1` rewrites the copy instead.
  - `//formal/dire` model-checks each committed trace with `DireResolutionTrace.tla`, which
    pins every variable at every step. A matched trace reaches its last state and violates
    `TraceIncomplete`.
  - TLC therefore stays in `make test`; the Elixir integration lanes never run Java.
  - This replaces the first design, which ran TLC inside the integration test and would have
    copied a JDK into every lane.
- **Self-test.** One trace also emits one `__tamper_<var>` variant per model variable, each
  altering that variable in the final state. TLC must reject every variant.
- **What the traces corrected.** The first traces showed the resolution model was wrong about
  three paths:
  - ARP observations go through the census/sync path and never run the alias merge.
  - The mapper resolves by address, then by alias, and only then through DIRE.
  - The real route into `AliasGuard` is agent check-in.

  The model was corrected from the traces and the code, and two new defect switches came out
  of it.
- The trace tests are `:integration` tests on the shared srql-fixtures CNPG. Both are serial
  and have DB-backed rows in `test/INTEGRATION_SOURCE_DISPOSITIONS.tsv` and
  `build/integration_test_dispositions.bzl`: the resolution test because it uses a global
  telemetry handler, the lifecycle test because its sweep step creates a `SweepGroup` whose
  monitor schedules global Oban workers.
- **Lifecycle traces** (`test/support/dire_lifecycle_trace.ex`,
  `DireLifecycleTrace.tla`) drive ingest, merge, the resolver's conflict merge, unmerge, soft
  delete, sweep restore, agent check-in and purge, and record status, delete reason,
  identifier owners, addresses, `merge_audit` rows and the devices whose `identity_revision`
  each step moved.
  - An ingest is logged as `StartWork` then `Commit`. A black-box test cannot interleave a
    merge inside one ingest call, so `work` is never stale in a recorded trace and the fence
    switch stays model-only until the fence is enforced (#4618).
  - Two ghosts come from the harness: the identifiers a merged-away device owned when the
    merge ran, and the insertion order of `merge_audit` rows (`created_at` has one-second
    precision, so a merge and its unmerge can share a timestamp).
  - Each of the six traces is rejected by the model with the switch it demonstrates turned
    off, so it proves that defect on the real code, not only that the model allows it.
  - Building them corrected the model's citation for sweep restores: the model cited
    `event_writer/processors/sweep.ex`, which is not registered as an EventWriter processor and
    never runs (its insert also names a `raw_data` column no migration creates). The live path
    is `SweepResultsIngestor`, which has the same eligibility rule.
- Every trace is synthetic: documentation-range MACs, test-range addresses, generated ids.
  Nothing is captured from a running deployment.

### D8. Delivery

Three pull requests, each on a fresh branch from `origin/staging` after the previous one
merges, each through the `no-mistakes` pipeline:

1. This change, the TLC toolchain, `tlc_test` and its self-test.
2. `formal/dire/`: the resolution and lifecycle models with their `goal`, `witness_*`,
   `current` and `vacuity` configurations.
3. The trace recorder and witness integration tests.

GitHub issues for confirmed defects are filed after PR 2 lands, each citing its witness
configuration and counterexample.

## Risks and trade-offs

- **The model can be wrong about the code.** Mitigated by citing a function per action, by
  review against the source, and by trace validation, which fails when they disagree.
- **Bounds hide deep bugs.** Accepted. Every defect listed above needs at most three devices.
  Bounds are constants and can be raised for an occasional deeper local run.
- **TLC runtime creep.** The model is sized to one to two minutes per configuration; a
  configuration that outgrows the budget is split or given symmetry reduction, not
  left slow in `make test`.
- **A JVM enters the build.** TLC runs only on the JVM. The JDK is Bazel-hermetic and
  used only by these test targets.
- **Model and code can disagree about ordering.** Several witnesses depend on when a guard
  runs relative to a write, for example `Sync.Aliases` running after identifier registration.
  Each such dependency is cited in the model and was read from the code; trace validation (PR 3)
  checks it against real runs.