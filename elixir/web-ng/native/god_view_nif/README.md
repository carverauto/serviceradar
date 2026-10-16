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
does not revive them. Build replacements as separate resources so the accepted
index remains readable. Call `bitmap_index_close/1` when disabling or replacing
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
3 is except with one child. Operator strings are empty. Negation is relative to
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
steady admission cap is 64,000,000 bytes and transient reservations are capped
at 160,000,000 bytes per resource. Publication subtracts only a provably
unretained retiring revision when checking steady admission; old and new
allocations always remain charged against the transient limit. Full current
rows reuse unchanged facet/live sets instead of duplicating them under readers.
An allocation rejection leaves the published revision and membership unchanged.

The serving owner must admit at most two index resources, including any awaiting
reclamation, and at most two 32 MiB Atlas mappings. Those allocations sum to at
most 195,108,864 steady bytes and 387,108,864 transient bytes. This is not total
replica peak memory: Atlas export scratch (up to 32 MiB per export), server
portable buffers, existing world geometry, BEAM and GPU allocations are separate.

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
