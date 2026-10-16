# Review response

This responds to every finding in `review.md` without changing that independent
append-only review. The user confirmed current membership on each page on
2026-10-16. Proposal, design, requirements and tasks now describe the reduced
implementation. Architecture HTML artifacts remain explicitly pending refresh.

## Confirmed findings and changes

| Review | Resolution |
| --- | --- |
| A1, B1 | Keep server-side Roaring for authorized filtering, facets and aggregate intersections. Native measurements support this use. |
| A2, B8 | Replace the active per-tile JSON overlay with typed binary row masks/counts and existing health/flow fields, including coverage and timestamps. Remove JSON-only size encoding, browser Roaring/WASM, worker, XOR history and chunked baselines from phase 3. |
| A3, B9 | State plainly that there is no approved fleet-scale causal producer; legacy scene sets are not a fleet source. Other unsupported source mappings remain explicit errors. |
| A4 | Separate 500-row publication batches from pending capacity. Use byte-bounded native Roaring for coalesced ordinal dirty work, not a small integer-array capacity. Bound UID notification ingress separately and report overflow/reconciliation. |
| B2 | Preserve and repair the existing device dictionary: full u32, no sequence burn on repeat allocation, tombstones and retention-safe cleanup. |
| B3 | Keep current authorization at admission and delivery from release one, including counts/details/search/overlays. |
| B4 | Remove durable outbox, dedicated control stream, rescan-generation table and replica checkpoint machinery. Reuse existing hints plus rolling reconciliation. Audit actual transaction owners before adding broadcasts. |
| B5 | User chose live ordinal pagination. Each response pins one local revision, then closes it; subsequent pages can use any healthy replica. No owner routing or leases. |
| B6 | Remove result caching and dependency-promotion machinery; recompute until measurements establish a need. |
| B7, C7 | Defer interface dictionary/query/lifecycle work because release one has no interface-filter requirement. |
| C4 | The original 32-ID durable bucket capacity was inadequate. Raising it to 1,024 passed the 11,000-change test, but the entire bucket design is removed because capacity did not cure lock contention. |
| C5 | Confirmed against PostgreSQL: two transactions changing four distinct devices deadlocked through two shared buckets (SQLSTATE 40P01), aborting one inventory writer. Removed the unshipped migration and all bucket/relay/lease code. |
| C6 | Remove the extra database-trigger availability path. Reuse current availability semantics and the existing invalidation channel; do not create an independent availability event pipeline. |
| C8 | Keep device identity migration before its consumers and require combined migration/runtime validation. Parallel authoring is not proof that an incomplete deployment is safe. |
| C9 | Correct the proposal: Ash declares resources; explicit SQL owns sequence, trigger and retention invariants. No generated-DDL claim. |
| C10 | Remove the hint codec and lease operations with their unnecessary subsystem, rather than retaining unused correct helpers. |

## Findings that need qualification

- **C1:** The integrated commit `07fd3f2158` already contains
  `20261016040000_generalize_fleet_identity_dictionaries.exs`, including the
  interface table. The outbox migration ran later. Executing both exact
  migrations and raw inventory writes on a disposable fixture database passed;
  the claimed missing-table outage does not describe the integrated tree.
  Interface work is still being removed for scope, not because its table was
  absent.
- **C2:** That same migration installs canonical allocation hooks, so a raw
  device INSERT does allocate an ordinal. Direct PostgreSQL tests exercised
  INSERT, UPDATE, soft deletion, token-aware acknowledgment, late commit,
  overflow and 11,000 synthetic changes. The full Ash database ExUnit suite was
  not run; direct SQL and remote unit compilation do not substitute for it.
  Absence of a local `_build` does not determine whether Bazel remote tests ran.
- **C3:** Canonical lifecycle hooks cover raw creation and tombstones in the
  integrated migration, and merge soft deletion occurs in the same transaction.
  Missing old assignments still need bounded backfill. The revised design
  requires full writer and purge coverage, after-commit hints where present,
  and rolling reconciliation; it makes no claim that dictionary-only changes
  inherently broadcast notifications.
- **B4's suggested cursor:** `identity_revision` is per-device and does not
  increment for every indexed attribute; `modified_time` is not commit order.
  Neither plus a finite overlap proves coverage of arbitrary late commits.
  Keep full bounded keyset reconciliation until a better cursor is independently
  proven. Report database load and actual convergence rather than promising a
  thirty-second whole-fleet scan.
- **B4's writer gap:** Sync ingestion already invalidates after its identity
  fence returns, and AWX discovery defers events until its outer transaction
  commits. The concrete missing hint is mapper polled-device creation after its
  standalone upsert. Fix that caller rather than broadcasting prematurely from
  the shared nested-transaction helper.
- **A2's size estimate:** Sparse portable Roaring is not always two bytes per
  member: scattered high bits add container headers. The actual codec experiment
  below supports replacing it even more strongly.

## Executed evidence and limits

- Exact migration SQL on baseline-derived disposable fixture tables passed
  newer-token preservation, bounded slice rotation, 11,000-change capacity,
  durable overflow and late-commit discovery. The independent lock experiment
  then reproduced the new deadlock. Both scratch databases were dropped and
  their absence verified. This is rejection evidence for the removed design,
  not a claim that it is safe to ship.
- Core inventory unit shard passed with 1,043 discovered tests, 872 excluded,
  zero failures: BuildBuddy invocation
  `55eb5a47-81a7-4d3d-ba5e-2bb090062e43`. Database cases were excluded.
- The earlier native 1.1-million-device experiment retained 100 query pins
  and reached 64.0/90.2 MB after compact/sparse churn (invocation
  `02c8f8ee-e0e7-44c2-b7e9-2fe3193f7136`). That lifecycle was rejected; it is
  not current admission or memory acceptance. The eight-pin implementation
  passed native tests and sustained churn under unchanged 64 MB retained /
  160 MB transient index caps. Its tuple baseline is independent Rust, not
  the old JavaScript renderer.
- Synthetic 8,192-row codec experiment: eight baseline portable sets used
  24,664 bytes for dense IDs and 245,824 for sparse IDs; seven-byte typed row
  columns use 57,344 bytes regardless of ID distribution. Source-built codec
  reserved a 6 MiB maximum heap (4 MiB initially), adding approximately 305 KB
  runtime and an Emscripten dependency. Node measurements are not real-browser
  or GPU acceptance. The revised protocol removes this runtime entirely.
- The replacement codec produced a 59,469-byte full frame for 8,192 synthetic
  rows, including its receipts and envelope. Aligned count copies add 32,768
  bytes; Node decode and validation measured 1.24 ms p95 over 100 iterations.
  Actual-browser and GPU measurement remains pending.

The actual native Atlas-to-index 100-view workload passed three independent
runs with automatic flaky retries disabled: invocation
`6137b80f-5c80-4380-a498-8304fdc68ed1`. Each run completed 100 compact and
100 sparse views through eight admitted workers. Sparse request p95 was
393.8-415.8 ms and p99 456.0-507.8 ms; peak native charged allocation stayed
below 160 MB with explicit temporary-budget retries. Earlier runs failed and
exposed a fixed-size decoder reservation and a retained/transient accounting
race; both were repaired without raising those caps. This is native scheduling
evidence with a harness export gate, not 100 HTTP clients, authorization latency
or whole-process memory. Details and reproducible targets live in the
[native README](../../../elixir/web-ng/native/god_view_nif/README.md).

Integrated web application-domain checks passed (478 discovered, 413 excluded,
zero failures) in `48a6bc64-5365-41b0-b39d-2d1a90bbb3a4`. Web quality passed
in `d6a0a56f-6b17-4fe8-953e-94230cfc11ab`; its Phoenix shard failed the
timestamp formatter inventory after renderer edits. That drift is being repaired;
it is not reported as a green integration run. The real channel/binary HTTP and
two-replica database cases compile but remain unexecuted pending the hosted
fixture lane. Hardware lifetime acceptance is still in progress.

The user subsequently required visible AND/OR/EXCEPT map groups, literal tag
prefixes and IPv4/IPv6 containment over any current device/interface address.
Those additions are now explicit proposal/design/requirement tasks. They do not
restore the rejected browser Roaring, frozen-page routing, interface identities
or durable hint replication. Address-index memory and prefix/CIDR performance
need their own declared proof before acceptance.

