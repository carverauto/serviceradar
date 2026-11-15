## 1. Publisher foundation
- [x] 1.1 Implement count/byte-bounded concurrent publication and serial comparator.
- [x] 1.2 Implement bounded persistent handoff and source-close draining under the configured retry policy.
- [x] 1.3 Verify concurrent reconnect ownership and fail-closed certificate policy configuration. Records whose ACKs fail together share one replacement connection, and a configured policy without managed TLS inputs stops the worker before any connection. Delayed ACK concurrency, count/byte admission, oversized records, stable retry IDs/deduplication and source-close draining already had coverage.
- [ ] 1.3a Cover a policy revocation while ACKs are pending. Flowgger cannot exercise it today: the policy loader accepts only a root-owned path, so a test would need a production seam. `rust/cert-policy` tests own guard denial and socket closure.
- [x] 1.4 Measure the publisher change with synthetic load and equivalent durability. Loopback results from a shared workstation are in `consolidate-log-collectors/performance.md`; repeat on a quiet host before quoting a multiplier.

## 2. Native Zen and control plane
- [x] 2.1 Extract shared normalization with conformance for merge, null, numeric, aliasing, errors and custom rules. `rust/zen-normalize` owns it and the core NIF calls it; its expected records were produced by the JSON-text implementation it replaced.
- [x] 2.2 Retain native values across rules and compile outside the hot path. A `RuleSet` is compiled once; records stay Zen variables between rules. Each rule still gets its own copy of the record's containers, because no test establishes that every node type leaves its context alone.
- [ ] 2.2a Call the shared rule set from Flowgger with records built directly as Zen variables. Blocked on rule delivery (2.3, 2.4).
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
