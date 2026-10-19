# Review response

## Subsequent approved corrections

The user requires filtering whenever Atlas is enabled, using existing viewer
permissions. The separate default-off bitmap flag is removed; active-query
failure never becomes an unfiltered success. Atlas lifecycle shutdown still
reclaims resources. This supersedes earlier rollout-toggle assumptions.

The user also requested memory/processing-based admission before adopting any
facet-eviction policy. Synthetic high-diversity evaluation reproduced the old
1,024/4,096 group limits disabling simple queries despite available memory.
Native publication now reserves temporary postings and revision directories
before construction and drops those scalar count limits. Prefix unions combine
postings in balanced stages under the same memory and deadline bounds. This
does not alter the distinct compiled IP-range limit or authorize eviction.
Full publisher recovery, hosted database/scale acceptance and the other pending
review corrections remain required; native measurements alone do not close them.

The negotiated WebSocket probe completed; task 4.7 still awaits final integration
validation. Compression remains disabled. Historical GPU measurements retain
their original checkpoint provenance and are not measurements of the new head.

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

- **C1:** The pre-rebase checkpoint `07fd3f2158`, which is not an ancestor of this branch, already contains
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

## Follow-up review corrections

The next review's fixer timed out before committing. Its successful edits were
recovered, reviewed and corrected before integration; the timeout is not a
passing review. The user confirmed durable seed successors, retained dictionary
protection on rollback, and unchanged scale limits with cleanup reserved.

| Finding | Correction and acceptance boundary |
| --- | --- |
| Tile query errors returned 503 | Query and tile controllers share bitmap status mapping: malformed input is 400, unsupported predicates 422 and expression limits 413; only retryable responses advertise Retry-After. The actual channel/database owner covers both controllers. |
| Replaced watches orphaned query work | A channel retains its occupied slot until its bounded task exits. Reset/unwatch discard delivery without killing only the outer caller. The database owner exercises repeated cancellation while another client progresses. No global slot registry was added. |
| Pending Roaring bytes omitted from native-cap selection | Final admission includes the actual pending queue charge. At the cap, IP becomes explicitly unavailable while scalar publication progresses; limits remain 125 MB retained / 160 MB transient. |
| Prefix source version refreshed the whole form | Capability identity excludes only source versions. Full descriptors and frame freshness checks remain; real support changes still invalidate the query. |
| Seed succession stopped after eight retired identities | A durable successor pointer advances atomically with fresh identity creation and preserves the eight-read attempt bound, with observed-revision fencing and permanent ordinal reservation. |
| Migration rollback broke older cleanup | Keep permanent dictionary protection. Rollback requires compatible retention cleanup or paused cleanup; document this requirement instead of permitting identity deletion. |
| Scale observer/action deadlines overlapped | Account from the hosted runner's actual start, including checkout. Require full test/quiet/cleanup time before scale admission, bound observer and cleanup processes including forced-exit grace, and retain all existing limits. |
| Committing tests retained synthetic identity rows | Use guarded exact-identity cleanup only in disposable database fixtures, with transactional protection restoration. Production retention remains unchanged. |
| Old dictionary flags could resurrect deleted membership | Canonical device liveness is authoritative at query-source reads; no fleet-wide startup repair write. |
| Migration lock inversion | Acquire both required table locks without waiting before lifecycle DDL, retaining finite migration deadlines. |
| Literal prefixes silently trimmed | Reject empty or surrounding-whitespace values in both parser and visible controls; preserve internal spaces and the user's draft. |
| Reconnect reset retry history | Preserve exponential retry history through binding cancellation and reconnect; accepted frames, changed requests or real capability changes reset it. Membership replacement is transient. |
| Deadline test was scheduler-sensitive | Retain the 100 ms request deadline and use a 1,500 ms observable completion bound, within a five-second test timeout. |
| Scale runbook implied completed measurements | Mark combined hosted compact/sparse runs as unexecuted until actual receipts exist. Native-only and component GPU measurements remain separate. |

The staging-finish comment finding was rejected after checking ownership: the
stage is consumed, while the last accepted revision stays available. The comment
describes the accepted revision, not retention of the stage.

A fresh physical-GPU probe also found that transparent zero-radius glyphs could
still be picked through their nonzero stroke. The corrected layer sets stroke
width and minimum pixel size to zero while reusing original geometry. The public
GPU test includes a visible underlay to distinguish a hidden hit from no rendered
scene. Camera acceptance now waits for current camera, receipts, sequence and
render completion; the transport uses the production numeric watch identifier.

Native-cap RED `af614604-e53e-4a85-89c2-d68c3862b5ee` became GREEN with 37 native
tests in `9e431e15-7b97-4dd3-8edb-7c49d6a3c410`. All ten web unit shards passed
in `2b7cc820-6d22-41a9-92e3-43a35f488d73`; its workflow contract failure was
corrected separately. The final workflow contract passed in
`fac207b1-c616-4b11-a848-09d101d122b1`, after deliberately disabling admission
made both negative budget cases fail in `4296db48-171a-4ae2-b785-cb0a56f6a4e4`.
Browser scene tests (652), eight SwiftShader GPU cases, declared lint and the
existing TypeScript scope passed in `73840a94-e01d-4d55-8b25-2869be7a4a2e`.
The combined remote `make test` then passed 419 targets with two platform skips
in `c3633e44-7fc4-4e08-b8fa-2a89e5ed5f03`, at pre-rebase local runtime checkpoint
`2a3032e125`. `2a3032e125` and `fe8915c30c` are pre-rebase checkpoints and are
not ancestors of this branch. The on-branch subject is `e9116e3ca7`. That
recorded run was not repeated on this tree.
Hosted database and compact/sparse scale acceptance remain pending. Fresh physical Apple WebGPU checks passed on
the integrated browser sources, including empty-filter picking with a visible
positive control, tile eviction, retry/rejoin, capability refresh and full device
teardown. The exact artifact and measurement limits are recorded in
`docs/topology-bitmap-gpu-acceptance.md`.

Identity RBE quality and sweep tests passed in
`fb8c3314-1401-4da8-8a48-8994f4c0a9d8`. The hosted owners still must execute the
new repeated-seed, concurrent-writer, migration and committing-fixture cases;
the database-free tier excludes them.

The portable artifact receipt now distinguishes optional web fonts from embedded
operational assets and qualifies unchanged diagram bytes relative to the prior
feature-branch refresh. The published topology page links to the protocol on
GitHub rather than a file outside the Docusaurus tree. All five embedded source
hashes match their canonical files and the embedded diagram bytes match the
delivered diagram. A fresh visual containment check was not run because browser
policy refused local file URLs; the earlier diagram receipts remain historical.


## Current review recovery

Run `01M52WPF0MN3F45GSFYS3PN67F` reached its correction-agent timeout before
committing the remaining fixes. Custody returned at pre-rebase checkpoint
`59adc905f8`, which is not an ancestor of this branch; all 74
successful recorded edits and the artifact refresh were reconstructed from the
durable tool journal. Recovery did not waive any finding or establish acceptance.

| Finding | Correction and acceptance boundary |
| --- | --- |
| Purge lost partition and unallocated tombstone lineage | Preserve partition. Allocate missing permanent tombstoned ordinals inside the existing bounded purge transaction before scrubbing payloads. Keep merge and seed-successor lineage, recheck deletion under canonical row locks and retain internal-device exclusions. The user approved this behavior for legacy tombstones. |
| Clear left retained Deck attributes hidden | Include membership-enabled state in all four layer update-trigger sets. The actual Deck regression retains geometry and style identities through pending, missing-receipt and Clear states, then checks public picking. Its missing-receipt setup is a component boundary, not a backend-route claim. |
| Camera publication preceded Deck initialization | Wait for the actual initialized renderer before reading its viewports; destruction cancels retry. The existing real Deck/ViewManager owner covers delayed startup and camera sharing. |
| Incomplete ordinal scans delayed geometry and churned mappings | Compare dictionary epoch/MAX/COUNT progress before restarting the optional scan, bound source reads to five seconds and yield to a newer geometry world after each page. Preserve the installed resource when sealed assignments are identical. MAX/COUNT still scans the dictionary; combined hosted scale must measure its cost. |
| Late membership callbacks reused the same signature | Fence every watch callback with a request-instance identifier as well as its view signature. A reset for an old view cannot clear the current channel watch. |
| Channel query budget included tile receipts | Apply the existing expression budget to the query; separately bound receipt metadata at 64 KiB before JSON encoding. Bulk membership stays binary. |
| Channel reasons exposed native/internal failures | Use the HTTP reason allowlist for channel failures and preserve the two documented transient membership reasons. Unknown reasons become query_unavailable. |
| CIDR literals silently trimmed whitespace | Reject surrounding whitespace at both parser and address boundaries. |
| Native close/query and ordinal guards lacked decisive coverage | Recheck closed state while acquiring the pin guard; make ordinal error assertions fail when the expected error is absent. Keep deterministic reclamation in the test owner. |
| Fixture teardown and assertions missed their intended state | Remove NOWAIT from guarded disposable-fixture teardown, clean exact synthetic dictionary-version rows, correct committing fixture cleanup and repair misplaced Armis comments. Production dictionary protection remains in force. |
| Binary truncation test failed an earlier guard | Supply matching declared and actual shortened lengths so validation reaches the truncated column. |
| Artifact citations implied current validation | Label pre-rebase local checkpoints and historical containment receipts explicitly. The current portable refresh has no new browser containment receipt. |

Browser corrections passed 653 scene tests, all nine software-WebGPU cases,
declared lint and the existing TypeScript scope in
`f4da3820-b4a2-42da-967d-86814b5a4c34`. Removing only the new update triggers
failed Clear restoration in `f4a69b39-9174-4ad7-a1e4-241daa3942ca`, while eight
GPU siblings passed. Removing renderer-readiness and request-instance guards
reproduced the Deck startup assertion and stale callback failure in
`d5e741b1-d919-49bb-bea8-b7d625cc82a4`, with 651 other scene cases passing.
These are focused source checkpoints. They do not replace full integrated review,
hosted database execution, compact/sparse acceptance or fresh physical GPU proof.

Identity formatting/Credo, inventory, discovery, sweep and test-routing targets
passed in `c64d8c85-3c01-467b-98a5-bfd163ba35ae`. The executed unit counts were
1,040 inventory, 285 discovery and 72 sweep cases, with zero failures. Their
excluded database cases include the new unallocated-tombstone and concurrent
restore regressions; those still require the ordinary hosted fixture lane.

The stale-reset channel regression passed with the fix, then failed only its
watch-preservation assertion when the digest guard was removed in
`9a58f0ae-18cb-4e56-a33a-8d37209e0fb1` (795 tests, one failure on both attempts).
The restored source and web quality passed in
`0bc00e05-a3e2-4307-8d5f-3829bc08b92d`. The earlier invocation
`1dcdc8f4-74bb-45d6-8ed8-e5f734129fbe` passed its Phoenix target but exited
nonzero because a second requested target name did not exist; it is not reported
as an overall pass. The regression drives the channel callback and checks the
emitted binary transport frame, without a public test-only predicate.

Native/loader corrections passed six remote targets in
`30d6ab6b-e7da-4bd7-8a50-c71451a2c2b4`: web quality, application-domain and
Phoenix shards, 37 native index cases, two ordinal keeper cases and two ordinal
scale cases. Disabling identical-assignment retention failed only the stable
mapping assertion in `170e7092-0971-4e4b-8b3f-96d62bd67e46` on both attempts.
The restored source passed. The 1.1M-device native projection retained 4,400,176
bytes; compact export p95 was 16.96 ms with 139,408 portable bytes, and sparse
export p95 was 40.04 ms with 967,608 portable bytes. These native scenarios
completed digest sealing but did not time it separately. They do not measure
database COUNT cost, loader polling or concurrent HTTP viewers. The new actual
loader/receipt database owner cases were loaded and excluded in the unit tier;
only hosted execution can establish those results.

The integrated remote `make test` passed 419 targets with two platform skips in
`170c8616-569a-492c-8695-def84af6a4a5` at pre-rebase runtime checkpoint
`ad967f6d6b9e85e871ab873b5267788bb412423e`, which is not an ancestor of this
branch. Browser, retention, channel and native
corrections are integrated. All three child leases were returned after exact
content checks and preserving their remaining recovered baseline patches.
The main feature lease remains held for full no-mistakes review and publication.
Ordinary hosted database and sequential compact/sparse acceptance still must run
against the reviewed published commit; this unit gate does not execute them.

A final review also retained the complete-world fast path: permanent assignments
for a fully mapped immutable world do not change when unrelated identities are
allocated. The loader skips both COUNT and identity pages until the world or
dictionary epoch changes. The existing hosted owner scenario now proceeds from
an incomplete mapping through the late commit to a complete mapping, allocates
an unrelated identity, waits for a real loader task and rejects count/page reads.
This database case remains unrun in the unit tier. The `ad967f6d6b` unit receipt
above predates this final fast-path correction.

The final integrated remote `make test` passed 419 targets with two platform
skips in `afe6cf35-2ec3-4d95-bbed-bee09930704f` at pre-rebase runtime checkpoint
`18ff6bd6d01a6c45c18624386558f161cae9d9d2`, which is not an ancestor of this
branch. The recorded run was not repeated on this tree. Do not treat
`77eaecceb6` as that same gate. The command exited zero on the historical
checkpoint. Hosted
database and combined compact/sparse acceptance remain pending; no new physical
GPU or portable-document containment result is implied by this unit gate.

## Resumable publication and projection corrections

The next review identified three remaining progress failures. A memory-rejected
scan page could block later deletions; Prefix Tag preparation restarted work or
performed an unbounded sort; and optional ordinal projection restarted complete
dictionary scans after interruption. The corrected publisher defers rejected
pages without acknowledging that pass, preserves capacity staleness until a
clean pass, and rotates one resumable catalog source per turn. Native catalog
counting, collection, in-place heapsort and label counting all yield with their
state retained. The loader retains its private mapping and cursor across
single-page tasks, polls the geometry head before each turn, separates projection
backoff, recovers lost sealing completions and checks the dictionary epoch again
before installation.

The catalog regression failed on the interrupted draft in remote invocation
`f55d05ab-d3c0-4769-825c-038464e1d4d9`: one long-deadline call processed the entire
large catalog instead of yielding. The corrected native core suite and NIF build
passed in `4dcd7349-5144-49da-8aed-7ffe035f4d2d`. Its 131,072 synthetic references
exercise incremental construction, independent sorted-label/range expectations
and reservation release. Hosted publisher and loader scenarios now exercise
real memory admission, later tombstones, task cancellation and lost sealing
completion; those database cases still need execution on the reviewed head.

The same correction retains purged AgentLinks lineage and avoids assigning an
address held by another live device, uses actual SQL savepoints for mapper retry,
binds DIRE seed roots and successors to the swept synthetic address, and reuses
an application-owned Prefix Tags registry in tests. Workflow trigger assertions
now inspect parsed YAML; telemetry isolation is checked in the real test owners
instead of counting source strings. The redundant derived WebSocket assertion
is removed while the actual negotiated-wire assertion remains. Binary-path and
GPU provenance documentation are corrected. These changes do not close hosted
database, generated-trace or combined compact/sparse acceptance.

The corrected working tree on checkpoint `b0bff03738132c80d7485604995b60619ea43b3b`
passed the complete remote `make test` gate in
`70ff6673-e160-4285-8736-815695425d6c`: 419 targets passed and two Swift platform
targets were skipped. This receipt covers the corrections above before their
commit; it is not evidence for an unchanged `b0bff037` checkout or a later rebase.
The unit tier still excludes the hosted database scenarios. Full no-mistakes
review, exact published-head CI and the remaining acceptance runs are pending.
