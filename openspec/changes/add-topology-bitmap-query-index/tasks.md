## 0. Proposal approval

- [ ] 0.1 Obtain approval for this proposal and its phased scope before implementation.

## 1. Persistent identities and bounded server index

- [ ] 1.1 Inventory all dictionary consumers and canonical create/merge/delete/restore writers; reuse device ordinals and specify interface identity projection.
- [ ] 1.2 Add Ash resource/migration changes for checked full-u32 storage and sequence capacity, preserving existing IDs, tombstones and rollback compatibility.
- [ ] 1.3 Add bounded, resumable allocation/backfill and durable coalesced dirty work covering raw bulk writers and late commits.
- [ ] 1.4 Implement the Rust index resource and integrate one bounded publisher with world-health lifecycle, coherent revisions, reader limits and reconciliation.
- [ ] 1.5 Implement canonical inventory/availability indexes, value and memory caps, and explicit unavailable/stale states.
- [ ] 1.6 Prove identity persistence, merge/delete/restore, crash replay, high IDs, epoch rejection and complete current-state convergence with behavioral tests.
- [ ] 1.7 Add declared synthetic Bazel benchmarks comparing set algebra and memory with the current array baseline; publish measured results.
- [ ] 1.8 Add transactional outbox-to-JetStream fanout, leased per-replica delivery/checkpoints, bounded retention and durable rescan fencing; prove two-replica pause/reseed and crash replay.

## 2. Authorized query, facets and tiled membership

- [ ] 2.1 Implement bounded expression validation/normalization, AND/OR/ANDNOT, exact conjunctive facets and revision-bound ordinal pagination.
- [ ] 2.2 Derive effective visibility from current RBAC/policy and enforce it on admission, delivery, counts, cache hits, details and streams from the first enabled API.
- [ ] 2.3 Add dependency-aware bounded result caching and dirty-ID patch/invalidation, including negation, live universe and authority changes.
- [ ] 2.4 Bind queries to admitted tile receipts; compute authorized leaf/aggregate/bundle membership without relayout or whole-fleet browser enumeration.
- [ ] 2.5 Specify and test canonical site/role, causal, alert/incident, impact and complete search adapters; expose only supported predicates and retain separate availability semantics.
- [ ] 2.6 Prove reference-evaluator parity, empty results, bounded pages, stale cursors, revocation races, count isolation and layout/geometry independence.
- [ ] 2.7 Route pinned query/cursor requests to their fenced index owner and prove non-owner ingress, owner loss and explicit restart behavior without load-balancer affinity.

## 3. Binary browser membership

- [ ] 3.1 Define the binary envelope, state domains, length and allocation limits; pin the portable Roaring codec and browser dependency through approved dependency tooling.
- [ ] 3.2 Add Rust-to-WASM synthetic interoperability fixtures covering empty/sparse/dense/run containers and unsigned high IDs, plus malformed input rejection.
- [ ] 3.3 Implement atomic baselines, XOR deltas, acknowledgments, sequence/epoch fencing, chunk assembly, cancellation and bounded slow-consumer reset.
- [ ] 3.4 Decode real bitmap bytes with roaring-wasm, derive admitted-row masks, and keep Arrow attributes typed without an added whole-scene WASM round trip.
- [ ] 3.5 Add the rollout flag and explicit unsupported-filter fallback; release membership on tile eviction, disconnect and feature disable.
- [ ] 3.6 Run browser zoom/eviction/reconnect/resource-lifetime tests and measure CPU/WASM/GPU retention and upload copies.

## 4. Scale proof and delivery

- [ ] 4.1 Meet and publish the issue's p95 targets on the declared 100k + 1M synthetic fixture, including full-population churn bytes and sparse ordinal cases.
- [ ] 4.2 Measure sustained churn, 100 concurrent view subscriptions, cache/high-cardinality limits, replacement headroom and convergence under restart/overload.
- [ ] 4.3 Run required remote unit/integration checks and actual-hardware browser acceptance; report each unrun check and limitation.
- [ ] 4.4 Update README and binary-path documentation to match shipped behavior, measured copies and tested scale; remove metadata-only bitmap claims.
- [ ] 4.5 Refresh Archify/portable review artifacts, obtain rollout approval separately, and archive only after the implemented change has shipped.
