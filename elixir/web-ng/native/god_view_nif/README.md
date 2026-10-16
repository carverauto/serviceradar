# Native topology membership

`bitmap_index.rs` owns persistent ordinal membership; `bitmap_nif.rs` is its
bounded typed BEAM boundary. The index does not own device UIDs, coordinates,
current RBAC or durable delivery. Those remain with inventory, Atlas and the
supervised publisher. Bulk membership uses portable 32-bit Roaring bytes.

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
that exact result. `bitmap_query_view_sets/5` returns portable member bytes,
followed by the requested facet subsets in request order, from the same pin.
It does not change or rebuild geometry.

Admission limits are 32 predicates, depth 8, 65 instructions, 50 facet counts,
128 page rows, 8,192 admitted leaf IDs, 16 view subsets and 256 KiB of serialized
view sets. Pins live for 30 seconds, with 128 retained handles and eight active
readers. The owner periodically calls status to expire idle pins. Every read
has a deadline of at most one second. Unsupported or cardinality-capped facets
fail explicitly; the index never returns a partial facet as exact. A canonical
value exceeding 256 bytes also makes its whole facet unavailable until rebuild,
while other facets and live membership keep publishing. Missing values use the
exact literal `unknown`; values are not truncated or silently dropped.

Posting sets are immutable and shared across revisions; only changed postings
are replaced. Conservative native accounting includes bitmap container
capacities, map/string metadata, retained revisions and query results. The
steady admission cap is 200,000,000 bytes and transient reservations are capped
at 400,000,000 bytes per resource. A serving owner preparing a separate
replacement must additionally bound the sum across both resources. These
figures are not total BEAM or GPU memory.

## Verification

The regular native test target owns algebra, publication, lifetime and budget
behavior. `test/phoenix/topology/bitmap_index_native_test.exs` separately verifies
the actual BEAM ABI and binary round trip. `bitmap_interop_fixture` generates
portable empty, sparse, dense and run-container inputs from the shipping Rust
serializer for independent browser codec tests.

Run the synthetic scale target on BuildBuddy:

```
bazel test -c opt --config=remote \
  //elixir/web-ng/native/god_view_nif:bitmap_scale_benchmark --test_output=all
```

It declares 100,000 invented infrastructure devices plus 1,000,000 invented
endpoints, compact and sparse high-u32 ordinals, facet distributions, hardware,
warmup and sample count. It checks result parity, reports p50/p95/p99, and runs
100 one-percent publication ticks while 100 queries retain older revisions.
The array baseline is an optimized Rust tuple count scan, not a browser frame
timing. Churn bytes cover all changed portable state sets; the protocol test
must add its real envelope. Process RSS includes benchmark scaffolding and is
reported separately from conservative index accounting.

The initial BuildBuddy run
[2278ce3c](https://carverauto.buildbuddy.io/invocation/2278ce3c-791b-41b2-aac9-8f4b56be7250)
measured compact/sparse query p95 of 0.220/1.112 ms, query plus 50 facet counts
of 2.70/3.74 ms, and 64.0/90.2 MB retained native accounting after sustained
churn. The sparse tuple count scan was faster than the bitmap result query in
that run. These native measurements do not certify distributed freshness,
authorization latency, complete wire bytes, browser heap or hardware FPS.
