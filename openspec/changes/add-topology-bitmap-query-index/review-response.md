# Review response

This responds to every finding in `review.md` without changing that independent
append-only review. The user confirmed current membership on each page on
2026-10-16. Proposal, design, requirements and tasks now describe the reduced
implementation. Refreshed architecture HTML artifacts and their review receipts
are committed alongside this change.

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
  and reported 64.0/90.2 MB after compact/sparse churn (invocation
  `02c8f8ee-e0e7-44c2-b7e9-2fe3193f7136`). That lifecycle was rejected; it is
  not current admission or memory acceptance. Later verification found that
  Roaring's bitset statistic reports bits despite its byte-oriented name, so
  those old charged figures overstated actual bitset storage eightfold. Current
  scalar and address results use the corrected counter. The address-capable
  index enforces 125 MB retained and 160 MB total reservation caps, with eight
  query pins. Its tuple baseline is independent Rust.
- Synthetic 8,192-row codec experiment: eight baseline portable sets used
  24,664 bytes for dense IDs and 245,824 for sparse IDs; seven-byte typed row
  columns use 57,344 bytes regardless of ID distribution. Source-built codec
  reserved a 6 MiB maximum heap (4 MiB initially), adding approximately 305 KB
  runtime and an Emscripten dependency. Node measurements are not real-browser
  or GPU acceptance. The revised protocol removes this runtime entirely.
- The replacement codec produced a 59,469-byte full frame for 8,192 synthetic
  rows, including its receipts and envelope. Aligned count copies add 32,768
  bytes; Node decode and validation measured 1.24 ms p95 over 100 iterations.
  This earlier Node-only measurement predates the exact-total header field;
  physical-browser and GPU evidence is recorded separately below.

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

Integrated checks now pass in `ac3da572-16db-426f-8cc7-94802131f96c`:
web quality, application-domain (478 discovered, 413 excluded) and Phoenix
(783 discovered, 212 excluded), both with zero failures. The earlier timestamp
inventory failure was repaired. Real channel/binary HTTP and two-replica database
cases compile but remain unexecuted pending the hosted fixture lane.

Physical-GPU stress completed sixteen zoom/pan cycles, reconnect, authority
replacement, disable and a four-cycle remount with no validation errors and zero
tracked devices/buffers after teardown. It found and repaired shared mutable
compute bindings in the pinned Luma dependency, independently reproduced through
the public compute API. The harness uses synthetic HTTP/WebSocket responders;
it does not prove the real server/database path. Scope, bytes and timing are in
[GPU acceptance](../../../docs/topology-bitmap-gpu-acceptance.md).

The user subsequently required visible AND/OR/EXCEPT map groups, literal tag
prefixes and IPv4/IPv6 containment over any current device/interface address.
Those additions are now explicit proposal/design/requirement tasks. They do not
restore the rejected browser Roaring, frozen-page routing, interface identities
or durable hint replication. Address-index memory and prefix/CIDR performance
have separate declared proof.
Existing named Prefix Tags are also approved. Their local immutable snapshots
now supply bounded native network ranges, preserving the existing full matching
chain and live pagination. This adds no interface identities, query-owner routing
or per-device BEAM lookup; catalog and range costs are explicitly bounded.

Native invocation `49a2c6f0-de5c-4c6c-9315-6f3bc99f0c4d` passed 35 native tests,
778 web tests and scalar, Atlas-view and address benchmarks. Corrected scalar
memory after 100 churn ticks was 7.94/19.21 MB compact/sparse. The separate
2.2-million-association address benchmark retained 71.00/83.15 MB after 100
one-percent mixed churn ticks; sparse total reservations peaked at 140.68 MB.
All 100 concurrent native address queries completed with bounded harness retries,
at 64.47 ms sparse request p95. The native README records pin-release retries,
monotonic synthetic IPv6 assignment and excluded database/transport costs.
These experiments do not prove a combined address-plus-Atlas-view peak.

Source/parser/catalog integration passed 787 web tests with zero failures
(212 database exclusions), plus quality in
`b3a57067-4654-49e5-a4fc-ae01acb8189e`. The production filter and capture fixture
passed 635 scene tests and seven WebGPU checks in
`56545d47-fc2d-4d3a-939f-a8143c12fe0a`. Two real 1600x1000 browser captures
show the requested expression returning 160 matches from 1,024 invented devices,
with identical camera and decoded geometry. They use synthetic transport and
do not replace the hosted database/channel acceptance lane.

Final delivery checks now run geometry, canonical mapping and fresh authority
checks inside the original one-second request budget. A suspended geometry owner
reproduced the unbounded-call failure in `028c8130-a5da-40d5-a5f1-ca2645329aaf`;
the fixed deadline regression and web quality passed in
`f21041bc-d8a0-4971-8bd7-b8f5eb271138`. Canonical mappings retain their two-slot
native admission permits through actual reclamation, and health snapshots no
longer retain those separate mappings. The full remote `make test` gate passed
414 targets with two Swift platform skips in
`c3499e7a-246b-4498-9611-9e084119a583`, a later integrated run than
`2acf322c-fbc1-4bba-8257-2a137605223e`. Both predate the latest review fixes and
do not prove the final head. Database-backed acceptance remains a separate
hosted gate. Historical commit identifiers elsewhere in this report name the
tested pre-rebase checkpoints, not the current branch head.

## Pass 3 response

- Naming: public prose and new UI copy use ServiceRadar Atlas. Existing source
  identifiers, flags and capability names retain their current spellings.
- P3-1: retain full-replacement membership frames. The negotiated WebSocket
  matrix for 1, 10 and 100 clients is recorded in
  `docs/topology-bitmap-websocket-measurements.md`. Compression stays
  disabled. Unchanged-tile omission stays deferred.
- P3-2: accept native Arrow IPC health/flow encoding as an explicit follow-up,
  consistent with the binary-path audit. The current SRTO codec remains in this
  release; the follow-up must preserve receipts, nullability, coverage and
  timestamps while comparing actual allocation and wire costs.
- P3-3: website capture delivery is complete separately at
  `6ec38c9180f8035b3893cb91577a49850b072147`, with 72 tests and no pull
  request, on `carverauto/serviceradar-web` branch
  `blog/set-algebra-over-device-groups`. The captures use synthetic inventory
  and transport and do not prove server or database acceptance.

## Final implementation review corrections

The implementation review is tracked separately from the original proposal
review. The following corrections preserve the approved scope and budgets:

- Browser membership uses displayed geometry receipts; offscreen prefetch does
  not restart a live filter. Telemetry tiles are admitted in deterministic
  numeric tile order before fetching, within the existing five-MiB budget.
  Omitted telemetry remains unknown instead of creating an eviction/refetch loop.
- Malformed frames and resets retain exponential retry history until a complete
  frame is accepted. New watches use fresh view epochs. SRTO text decoding
  preserves a leading BOM in identifiers, and SRMO counts cannot exceed row
  population or assign membership to boundary rows.
- Parser and builder limits count EXCEPT instructions and the root level:
  32 predicates, 65 compiled instructions and eight levels. Native-backed tests
  accept the exact boundary and reject the next instruction or level.
- Transient index warmup leaves the geometry manifest and its canonical mapping
  intact for normal polling. Disabled indexing remains a distinct state. Named
  Prefix Tag delivery rechecks feature enablement within the original deadline
  after current authority and source validation.
- The proposed multipart-upload crash did not reproduce with pinned Jason:
  nested Plug.Upload values already produce HTTP 400 invalid_query through the
  actual controller boundary. A public regression retains that contract; no
  speculative rescue was added.
- Retention preserves old UID, ordinal and deletion lineage. Fresh seed
  successors remain bounded and policy-aware; source-retired identities remain
  suppressed. Scrubbing restores structural defaults and valid fresh timestamps
  without retaining historical payload. Service components are excluded from
  new allocation and projection while old reserved assignments remain intact.
- Dictionary widening precedes inventory lifecycle DDL in a separate migration;
  both use finite lock and statement timeouts. The heavy dictionary rewrite does
  not retain the inventory lifecycle lock.
- Duplicate native facet keys are rejected atomically. Publication validates
  outside the short revision guard, and immutable Prefix Tags catalog readers
  share a read lock while preparation and release use nonblocking writes.
- Scale fixtures use unique synthetic IPv6 primary addresses and a shared IPv4
  interface address. New inactive devices precede their invented dictionary
  assignments, then normal activation triggers run in the same transaction;
  this respects the immediate foreign key without remapping existing identity.
  Final predicates verify replaced addresses. Revocation must increase every
  client's denial counter after deactivation. The network client's retry
  schedule matches the browser and resets only after a complete frame.

Focused browser regression cases first failed against the earlier implementation
in `fd272658-c0d4-48f5-8314-1a8cb174e5f8`, then 644 scene tests passed in
`284ed484-a2fa-418d-89d0-87bdf2f94401`. Parser depth and instruction bounds
failed in `bf70fe99-983e-4ad9-8aeb-64c80a822398`; the corrected parser/native
boundary, controller upload contract, application-domain shard and web quality
passed in `f90ed680-bfc5-4c9e-89a9-416fe3b36a84`.

Identity-focused invocation `7f0f29c3-6ec7-45c5-b024-0f105da73792` passed core
quality, the core shard (1,290 tests, zero failures, one skipped), sweep tests
(72 tests, zero failures) and the Phoenix sibling target. Its web-quality failure
was an existing overlong frame-test line, corrected in the later passing server
run. Native duplicate-facet rejection first failed in
`83b12f11-466a-46e7-916d-6acfed9a503f`; the corrected 36 native tests, nine
Prefix Tags Rust tests and Phoenix NIF coverage passed in
`733e7ce1-fce3-4abe-b7b9-f641b597a538`.

These are focused revision checkpoints, not final integrated acceptance. Hosted
migration, database lifecycle, real channel and compact/sparse combined scale
execution remain required. In particular, database-free parser and controller
checks do not prove disable-during-authority or persisted-world polling races.
