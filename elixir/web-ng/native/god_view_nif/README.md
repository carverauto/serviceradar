# Native topology membership

`bitmap_index.rs` owns persistent ordinal membership; `bitmap_nif.rs` is its
bounded typed BEAM boundary. The index does not own device UIDs, coordinates,
current RBAC or durable delivery. Those remain with inventory, Atlas and the
supervised publisher. Atlas-to-index membership uses portable 32-bit Roaring
bytes; browser overlays use typed admitted-row columns.

Create an unpublished index with 16-byte dictionary and index epochs, entity
kind and an allowlist of canonical facet keys. Publish full current rows in
batches of at most 500. A row is `{ordinal, live?, [{facet, value}]}`; zero is
reserved, missing supported values enter `unknown`, and a deleted ordinal is
removed from every posting. The expected revision serializes publication.
Repeated current rows preserve membership. Source revisions are opaque binaries.

The owner announces readiness only after seed/replay acceptance. Publishing
`ready=false` permanently fences earlier query pins; enabling a later revision
does not revive them. Ordinary reconciliation retains the accepted resource and
publishes revisions. Explicit replacement closes the old resource before
allocating another one. Call `bitmap_index_close/1` when disabling or replacing
an index, and close query handles when their server-side owner discards them.
These explicit releases run on dirty CPU schedulers.
Close fences queries immediately even if a running publisher/reader makes
cleanup return `publisher_busy` or `reader_busy`. Retain the closing resource
and retry; do not create another replacement until reclamation succeeds.

`bitmap_index_mark_dirty/3` coalesces at most 500 nonzero ordinals per call in
a native Roaring set. Its third argument requests a full source reconciliation.
`bitmap_index_take_dirty/2` removes up to 500 sorted ordinals before the owner
reads current rows. A failed read or publication must re-mark the taken IDs;
new hints received during that work remain queued. The set is capped at 512 KiB
of portable serialized bytes, with allocated containers and metadata also
charged to the index's native budget. Overflow releases the detailed set and
requests a full scan. Hints are not a durable delivery log; a periodic complete
keyset pass remains responsible for repairing missed notifications and deletes.

Both calls return pending count, serialized/native bytes, `rescan_needed`, and
`rescan_generation`; take returns `{:ok, {ordinals, status}}`. Index status also
includes this map as `pending`. Every overflow or explicit rescan request
advances the ephemeral generation. Capture that token before a full scan and
call `bitmap_index_acknowledge_reconcile/2` only after accepting the entire pass.
A different token returns `stale_reconcile`, preserving a request that arrived
during the scan. Acknowledgement never removes later pending ordinals. These
operations use bounded inputs, nonblocking lock admission and dirty CPU NIFs.

Queries use a bounded postfix program. Instructions are
`{opcode, facet, value, arity}`: 0 is an exact predicate, 1 is all, 2 is any and
3 is except with one child. Values are typed binary fields. Opcodes 4-7 are
literal, case-sensitive prefixes: 4 selects a facet value prefix; 5 selects
present tag keys by name prefix; 6 pairs a tag-name prefix with an exact value;
7 pairs it with a value prefix on the same key. Tag-name prefixes omit `tag:`.
Presence excludes the synthetic missing-value `unknown` bucket. An actual
value `unknown` still matches. Key presence remains exact when that key's
value cardinality exceeds its cap; value predicates reject unavailable facets.
Operator strings are empty. Negation is relative to
the live universe. The serving owner derives the authority fingerprint from
current permission checks, never from a client field, and rechecks permission
before delivery. Interface indices must not be exposed until a coherent parent
device visibility projection is installed; cross-kind algebra is rejected.

`bitmap_index_query/7` returns
`{:ok, {query_ref, revision, source_revision, cardinality}}`. Keep that complete
receipt with the authenticated server-side handle. It describes the pinned
result, even if a new index revision publishes before the response is sent.
Pages are ordered by unsigned ordinal, and conjunctive facet counts intersect
that exact result. Aggregate portable sets remain a server-side interchange
format; the browser consumes admitted row columns. Queries do not rebuild
geometry.

`bitmap_query_row_overlay/7` accepts at most 128 `{:leaf, ordinal}` or
`{:aggregate, portable_bytes}` selectors, with 8 MiB of combined aggregate
input, validated dictionary/index epochs and device kind. It returns four
binaries in input row order: matching u8 (0/1), causal u8 (unknown=3),
availability u8 (healthy=0, unavailable=1, unknown=2), and matched-device counts
as little-endian u32. All columns read one pinned revision. An aggregate is
healthy/unavailable only when its entire matched population has that exact
state. Mixed/empty populations are unknown. Leaf ordinal zero represents an
unmapped or unsupported population and returns a nonmatch with count zero.
The owner binds these columns to its exact tile receipt; a changed row order
requires a new complete overlay. No browser Roaring runtime is required.

Admission limits are 32 predicates, depth 8, 65 instructions, 50 facet counts,
128 page rows and 128 rows per overlay projection. Pins live for 30 seconds,
with eight retained handles and eight active readers. The serving owner closes
request-local pins when the request finishes; 30 seconds is a native expiry
backstop, not a cross-request cache. Every read
has a deadline of at most one second. Unsupported or cardinality-capped facets
fail explicitly; the index never returns a partial facet as exact. A canonical
value exceeding 256 bytes also makes its whole facet unavailable until rebuild,
while other facets and live membership keep publishing. Missing values use the
exact literal `unknown`; values are not truncated or silently dropped.

Posting sets are immutable and shared across revisions; only changed postings
are replaced. Conservative native accounting includes bitmap container
capacities, map/string metadata, retained revisions and query results. The
steady admission cap is 125,000,000 bytes and transient reservations are capped
at 160,000,000 bytes per resource. Allocation ownership distinguishes steady
published revisions, accepted query pins and the dirty queue from transient
expression/decode work. A shared admission lock atomically promotes new retained
allocations and retires only provably unshared old allocations. All allocations
remain charged against the transient limit until they are actually dropped. Full current
rows reuse unchanged facet/live sets instead of duplicating them under readers.
An allocation rejection leaves the published revision and membership unchanged.
The address capacity calculation includes facet metadata, catalog and address
overhead, and the retained dirty bitmap. Publication rechecks that charge under
the queue lock before admission and revision swap. Intrinsic overflow of the
next revision, without the queue, makes IP explicitly unavailable (`native_cap`)
while scalar membership keeps publishing. Queue bytes alone over the steady cap
reject the stage as retryable `pending` and leave the accepted revision, scalar
membership, and addresses unchanged. Pressure from old query pins or scratch
remains retryable.
Completed bitmap calculations transfer their scratch reservation into the
result allocation, releasing only the unused allowance. Failed transfers
release their reservation without retiring other readers' allocations.
The pinned roaring 0.11.4 statistics report bitset capacity in bits despite a
bytes field name; accounting uses 8192 bytes per `Box<[u64; 1024]>`. Array
statistics conservatively charge twice their u16 capacity. Earlier benchmark
memory figures below used the inflated bitset statistic and are historical
accounting results, not measurements of physical allocation.
Portable decoding reserves bounded scratch from input size, including the
checked decoder's allocation-before-EOF cases. Row intersection separately
reserves from both decoded operands, so run compression cannot hide expansion.

The serving owner admits one index resource, including any awaiting reclamation,
at most two 32 MiB Atlas mappings, and a global 4 MiB Prefix Tags catalog across
current and retained snapshots. Their retained ceiling is 196,303,168 bytes.
The index's 160 MB transient ceiling includes unpublished address staging and
old pinned revisions. Two 32 MiB Atlas export scratch slots, two 32 MiB mappings,
eight 8 MiB whole-view selector buffers and the 4 MiB catalog raise the explicit
allocation envelope to 365,520,896 bytes; eight 256 KiB encoded frames add
2,097,152 bytes. This is not total process memory: existing geometry, Prefix
Tags tries, source row terms and other BEAM/application allocations are separate.

## Verification

The regular native test target owns algebra, publication, lifetime and budget
behavior. `test/phoenix/topology/bitmap_index_native_test.exs` separately verifies
the actual BEAM ABI and binary round trip. Atlas independently verifies
portable aggregate membership against its existing detail iterator.

Run the synthetic scale target on BuildBuddy:

```
bazel test -c opt --config=remote \
  //elixir/web-ng/native/god_view_nif:bitmap_scale_benchmark --test_output=all
```

It declares 100,000 invented infrastructure devices plus 1,000,000 invented
endpoints, compact and sparse high-u32 ordinals, facet distributions, hardware,
warmup and sample count. It checks result parity, reports p50/p95/p99, and runs
100 one-percent publication ticks, each with eight request pins that close
before the next tick. Read operations are serial; this measures retained
request overlap with publication, not eight simultaneous CPU operations.
The array baseline is an optimized Rust tuple count scan, not a browser frame
timing. A typed-row benchmark covers 127 leaves plus a full-population aggregate
in one query revision; its four columns occupy 896 bytes. The browser protocol
test measures complete frame bytes separately. Process RSS includes benchmark
scaffolding and is reported separately from conservative index accounting.

The initial BuildBuddy run
[2278ce3c](https://carverauto.buildbuddy.io/invocation/2278ce3c-791b-41b2-aac9-8f4b56be7250)
measured compact/sparse query p95 of 0.220/1.112 ms, query plus 50 facet counts
of 2.70/3.74 ms, and 64.0/90.2 MB retained native accounting after sustained
churn with 100 long-retained pins. That pin lifecycle was rejected in favor of
eight request-local pins and smaller explicit limits; it is historical evidence,
not current acceptance. The sparse tuple count scan was faster than the bitmap
result query in that run. These native measurements do not certify freshness,
authorization latency, complete wire bytes, browser heap or hardware FPS.

The typed-row benchmark in
[ff73422b](https://carverauto.buildbuddy.io/invocation/ff73422b-5dd7-4a9c-bed8-b85dc6d4915b)
measured compact/sparse projection p95 of 0.146/0.507 ms for 127 leaves plus a
full-population aggregate, producing 896 column bytes. It starts with prepared
aggregate membership; Atlas traversal/serialization is measured separately in
`rust/topology-atlas/README.md`. The same invocation passed the native bitmap,
core NIF and web NIF targets; Atlas fixture corrections were verified in the
Atlas README's later invocation.

The current eight-pin lifecycle passed in
[327b995a](https://carverauto.buildbuddy.io/invocation/327b995a-f27f-48c9-9340-bb066f175b7a)
on a Xeon Gold 6258R executor. Compact/sparse peak retained index bytes during
100 churn ticks were 33.0/57.3 MB; after closing the request pins they were
30.7/46.3 MB. Query p95 was 0.256/1.301 ms, query plus 50 facets was
2.979/4.230 ms, and typed-row projection was 0.211/0.594 ms. One-percent
publication tick p95 was 37.6/59.7 ms; request-pin lifetime p95 was 38.8/70.2 ms.
The same invocation passed 31 native tests, including actual sparse allocation
rejection, unchanged published state after rejection, capacity recovery after
deletion, and query fencing while close waits for active work. The actual BEAM
ABI passed in
[3b243767](https://carverauto.buildbuddy.io/invocation/3b243767-6004-443d-adb9-ac3c65373d61);
its only failing test was the subsequently corrected capacity-recovery assertion.

The complete native view experiment is a separate declared target:

```
bazel test -c opt --config=remote \
  //elixir/web-ng/native/god_view_nif:bitmap_view_scale_benchmark \
  --test_output=all --flaky_test_attempts=1 --runs_per_test=3
```

It builds an actual Atlas world and canonical projection for the same synthetic
1.1M-device inventory, then traverses 64 tiles per view. This fixture emits two
leaves and one aggregate per tile. A saturation probe retains the first eight
native query pins and verifies that the other 92 attempts reject admission.
A second phase processes 100 complete views using eight native worker threads,
one deadline per request and ten warmups. Each view exports its actual aggregate
membership, projects all tile rows against one pinned query and checks exact
total counts against the arithmetic fixture oracle. A harness gate models two
Atlas export slots; its transient retries use a 100-microsecond backoff and are
included in reported latency. This is not the BEAM/NIF gate, an HTTP/channel
load test, or evidence that production callers implement those retries.

An initial run was flaky; three subsequent runs in
[1e02f956](https://carverauto.buildbuddy.io/invocation/1e02f956-4192-4217-b2f8-f479dbb1cc1b)
all rejected most sparse views. That exposed a steady admission check counting
other workers' transient allocations. Ownership-based accounting fixed it
without raising either limit. In
[6137b80f](https://carverauto.buildbuddy.io/invocation/6137b80f-5c80-4380-a498-8304fdc68ed1),
all three independent runs completed every compact and sparse view; the native
unit and sustained-churn targets also passed all three runs. Xeon Gold 6258R
executors reported sparse request p95 of 393.8-415.8 ms and p99 of 456.0-507.8 ms;
row projection p95 was 8.59-8.98 ms. Sparse native peak reservations reached
159.85 MB with 13-14 explicit memory-admission retries. Atlas admission dominated
latency, with approximately 76,000 retry attempts per 100-view wave.

Each sparse view exported 2,260,672 portable bytes and produced 1,344 typed
column bytes. Peak retained portable buffers across workers were 12.72 MB;
these are separate from index accounting. The canonical mapping was 4,400,144
bytes. The harness's two export slots can additionally retain up to 64 MiB
of Atlas scratch. Process RSS was approximately 446,184 KiB, including world
geometry and fixture scaffolding; neither that RSS nor the index accounting
is a complete replica peak estimate including BEAM/browser memory.

The actual BEAM boundary passed after the accounting change in
[f107f2a7](https://carverauto.buildbuddy.io/invocation/f107f2a7-3e5e-4ca6-ba94-ea505294db24).


## Complete address publication

`bitmap_index_begin_publish/5` stores at most 500 scalar rows and returns an
unpublished stage. Feed `bitmap_publish_addresses/3` at most 500
`{ordinal, address_binary}` pairs and 500 completed ordinals per call. Addresses
are numeric network-order 4-byte IPv4 or 16-byte IPv6 values. Every live scalar
row needs a completion marker, including devices with no addresses. Deleted
rows are already complete. Additions after completion or for other ordinals
fail explicitly. A stage has a 16 MiB native budget and ten-second lifetime;
the source transaction must finish within eight seconds to leave commit time.

`bitmap_index_finish_publish/2` consumes a complete stage and atomically replaces
both facets and complete address ownership in one revision. Incomplete stages
remain open for completion or abort. `bitmap_publish_abort/1`, last-resource
drop, and index close release staged allocations. The index keeps only a weak
stage reference, so cancellation does not retain a stage until its timeout.
`bitmap_publish_ip_unavailable/1` records source overflow while allowing scalar
publication. Status returns `ip_available` and `ip_unavailable_reason`.
`native_cap`, `source_cap`, and `not_seeded` stay sticky across later partial
stages; a stage of at most 500 rows never rebuilds a dropped address index.
Restoring IP requires a new index, or the first stage whose changed ordinals
cover every live device while no sticky reason is set. A nonempty legacy scalar
publication cannot certify addresses and marks IP unavailable as `not_seeded`.
An empty legacy publication preserves addresses for readiness changes.

Addresses use separate packed IPv4/IPv6 forward and reverse sorted leaf indexes.
Forward ranges select addresses before projecting to canonical device ordinals;
reverse lookup replaces every old assignment for a changed device. Shared
addresses retain every owner. Untouched leaves are immutable and shared, and
adjacent underfilled leaves are locally coalesced during updates. There is no
per-address scalar facet or device-level address bit slicing.

Opcode 8 is `{8, "", packed_address, prefix_length}`. Opcode 9 is one named
Prefix Tags range predicate, `{9, "", packed_ranges, 0}`. Each 33-byte record
contains family byte 4/6, a 16-byte inclusive low endpoint and a 16-byte inclusive
high endpoint; IPv4 endpoints are zero extended. Records must be ordered and
nonoverlapping. An empty selector matches no devices. The complete expression
allows 4096 ranges and 256 KiB selector bytes, separately from 16 KiB scalar
text. Both paths read the same revision as facets and use the shared one-second
deadline. Catalog matching-chain semantics remain with the existing Prefix Tags
snapshot producer.

Run the complete-assignment benchmark with:

```
bazel test -c opt --config=remote \
  //elixir/web-ng/native/god_view_nif:bitmap_address_scale_benchmark \
  --test_output=all --flaky_test_attempts=1
```

It generates 1.1M devices and 2.2M address associations, with one synthetic IPv4
and IPv6 assignment per device. IPv4 deliberately shares documentation-range
addresses. It checks /0, /32, /128, broad IPv6 ranges, literal tag prefixes,
100 concurrent queries on eight native workers, and 100 one-percent address
and availability churn ticks with eight revision pins. Publication retries only
after releasing old request pins when the actual cap rejects admission.
Native timings exclude the database source, HTTP/channel transport and browser.
IPv6 addresses are monotonic by invented entity number, so this fixture does
not establish update costs for shuffled address-to-ordinal assignments.

The complete pass in
[49a2c6f0](https://carverauto.buildbuddy.io/invocation/49a2c6f0-de5c-4c6c-9315-6f3bc99f0c4d)
passed 35 native tests, 778 web tests, both scalar benchmarks and the address
benchmark on a Xeon Platinum 8176 executor. Corrected scalar-only seed
accounting was 7.67/17.40 MB compact/sparse; after 100 churn ticks it was
7.94/19.21 MB, with peak retained overlap of 8.67/22.78 MB across eight pins.
Four-term query p95 was 0.262/1.248 ms; query plus 50 facet counts was
3.203/4.320 ms. All 100 native Atlas views completed
without memory-admission retries; sparse request p95 was 395.74 ms and index
peak reservations were 47.10 MB. Atlas admission still required harness retries.

For compact/sparse address indices, seed accounting was 71.03/82.43 MB and final
accounting after 100 mixed address/availability ticks was 71.00/83.15 MB.
Retained accounting with eight pins peaked at 124.97/125.00 MB, below the
125,000,000-byte cap; total index reservations peaked at 138.58/140.68 MB.
All 100 concurrent address queries completed, with two/three transient harness
retries and request p95 of 29.13/64.47 ms. Sparse query p95 was 0.83 ms for
IPv4 /0, 0.48 ms for shared IPv4 /32, 0.017 ms for unique IPv6 /128, 47.86 ms
for broad IPv6 /32 and 6.94 ms for a literal tag-value prefix. The mixed
one-percent tick p95 was 869.26/1324.90 ms across 22 bounded publications;
each tick explicitly released old pins and retried once after admission refused
their retained overlap. Process high-water RSS was 140,016/137,572 KiB and
includes fixture scaffolding, so it is separate from native allocation accounting.
The address benchmark and the 100-view Atlas benchmark are separate experiments;
they do not prove their combined peak or actual HTTP/channel request throughput.

Earlier sparse address seed runs
[088f6095](https://carverauto.buildbuddy.io/invocation/088f6095-3c36-4adc-9a15-9eb435953585)
rejected admission at 899,000 devices. Fixing reservation transfer then exposed
the pinned Roaring statistic's bit-versus-byte mismatch. The footprint regression
failed with the original formula in
[64914d7d](https://carverauto.buildbuddy.io/invocation/64914d7d-e4ac-4776-ac4e-e099e100242e),
reporting 65,792 bytes instead of 8,448 including metadata. The complete pass
above restores the corrected formula and checks both successful ownership
transfer and failed transfer cleanup. The earlier inflated accounting is not
evidence of actual allocated memory.
