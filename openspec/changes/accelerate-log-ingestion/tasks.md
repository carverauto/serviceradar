## 1. Publisher foundation
- [ ] 1.1 Implement count/byte-bounded concurrent publication and serial comparator.
- [ ] 1.2 Implement bounded persistent handoff and source-close draining under the configured retry policy.
- [ ] 1.3 Verify delayed ACK concurrency, admission bounds, oversized records, stable retries, certificate errors and shutdown.
- [ ] 1.4 Measure the publisher change with synthetic load and equivalent durability.

## 2. Native Zen and control plane
- [ ] 2.1 Extract shared normalization with conformance for merge, null, numeric, aliasing, errors and custom rules.
- [ ] 2.2 Retain native values across rules and compile outside the hot path.
- [ ] 2.3 Publish self-versioned effective rules through datasvc; reconcile rule scope.
- [ ] 2.4 Implement bounded fetch/watch/reconnect, atomic activation, cold start, empty snapshots and invalid/stale updates.

## 3. Binary and consumers
- [ ] 3.1 Specify metadata fields and complete OTLP/JSON field parity.
- [ ] 3.2 Implement byte/count/age batches with fixed retry bytes and one route/ruleset.
- [ ] 3.3 Adapt dual-format EventWriter consumption preserving all required side effects.
- [ ] 3.4 Verify persistence-before-ACK, partial failure/replay and StarRocks/CNPG parity.
- [ ] 3.5 Roll readers before opt-in producers; verify legacy retained-message draining.

## 4. Performance gates
- [ ] 4.1 Compare equivalent normalized data through Broadway and standalone Rust consumers.
- [ ] 4.2 Compare final warehouse JSON/CSV encoding and bounded load concurrency.
- [ ] 4.3 Record reproducible synthetic throughput/latency/cost evidence before selecting replacements.
