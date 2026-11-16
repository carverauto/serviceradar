## 1. Publisher foundation
- [x] 1.1 Implement count/byte-bounded concurrent publication and serial comparator.
- [x] 1.2 Implement bounded persistent handoff and source-close draining under the configured retry policy.
- [x] 1.3 Verify concurrent reconnect ownership and fail-closed certificate policy configuration. Records whose ACKs fail together share one replacement connection, and a configured policy without managed TLS inputs stops the worker before any connection. Delayed ACK concurrency, count/byte admission, oversized records, stable retry IDs/deduplication and source-close draining already had coverage.
- [x] 1.3a Cover a policy revocation while ACKs are pending. `//rust/flowgger:flowgger_managed_policy_test` runs as root on the remote executors with a real root-owned policy file and fails if it is not root; the same case skips in `flowgger_lib_test`.
- [x] 1.4 Measure the publisher change with synthetic load and equivalent durability. Loopback results from a shared workstation are in `consolidate-log-collectors/performance.md`; repeat on a quiet host before quoting a multiplier.

## 2. Native Zen and control plane
- [x] 2.1 Extract shared normalization with conformance for merge, null, numeric, aliasing, errors and custom rules. `rust/zen-normalize` owns it and the core NIF calls it; its expected records were produced by the JSON-text implementation it replaced.
- [x] 2.2 Retain native values across rules and compile outside the hot path. A `RuleSet` is compiled once; records stay Zen variables between rules. Each rule still gets its own copy of the record's containers, because no test establishes that every node type leaves its context alone.
- [x] 2.1a Make `strip_full_message` remove the field. Nulling a top-level field removes nothing, because Zen deletes the null from the rule's result and the overlay keeps the old value. A rule now removes top-level fields by naming them in `serviceradar_remove_fields`; only the bundled `strip_full_message` rule does, and the seeder refreshes seeded copies that are not user-authored. No other rule changes behavior.
- [ ] 2.2a Call the shared rule set from Flowgger with records built directly as Zen variables. Blocked on collector rule delivery (2.4).
- [x] 2.3 Publish self-versioned effective rules through datasvc; reconcile rule scope. `ZenRuleSync` publishes one digest-identified bundle per stream and subject at `zen/rulesets/<stream>/<subject>.json`, built from the rule list core's normalizer also reads; `rust/zen-normalize` verifies and compiles it.
- [ ] 2.3a Publish a rule set too large for one KV value as immutable documents under a manifest. Today datasvc rejects it and the previous bundle stays. Also observe a published bundle on a running deployment.
- [ ] 2.4 Implement bounded fetch/watch/reconnect, atomic activation, cold start, empty snapshots and invalid/stale updates. `ActiveRules` in `rust/zen-normalize` does activation, cold start, empty snapshots and invalid or stale updates. Still open: the collector's datasvc fetch, watch and reconnect, which needs the log collector to be granted datasvc access; datasvc roles are per identity for the whole store, not per key.

## 3. Binary and consumers
- [ ] 3.1 Specify metadata fields and complete OTLP/JSON field parity. OTLP protobuf rows now fill observed_timestamp, trace_flags, event_name, source_ip and scope_attributes like JSON rows (#6699). Still open: the collector-authenticated source identity and the syslog fallback fields on the binary path.
- [ ] 3.1a Decide whether Zen rules configured for `logs.otel` should apply to protobuf OTLP logs. Today they do not: protobuf is that subject's format and is stored without rules. Applying them means running Zen on every OTLP log.
- [ ] 3.2 Implement byte/count/age batches with fixed retry bytes and one route/ruleset.
- [ ] 3.3 Adapt dual-format EventWriter consumption preserving all required side effects. EventWriter reads collector-normalized OTLP batches from `logs.normalized.<kind>` without running Zen again, requires `Sr-Log-Schema: otlp-normalized-v1`, records `Sr-Ruleset-Id`, and never reads JSON there. Only the log collector's NATS user may publish that subject. Protobuf is refused on every other `logs.` subject except `logs.otel`, so switching format cannot skip a subject's rules. Still open: side-effect parity checks against a producer, which does not exist yet.
- [ ] 3.4 Verify persistence-before-ACK, partial failure/replay and StarRocks/CNPG parity.
- [ ] 3.5 Roll readers before opt-in producers; verify legacy retained-message draining.

## 4. Performance gates
- [ ] 4.1 Compare equivalent normalized data through Broadway and standalone Rust consumers.
- [ ] 4.2 Compare final warehouse JSON/CSV encoding and bounded load concurrency.
- [ ] 4.3 Record reproducible synthetic throughput/latency/cost evidence before selecting replacements.
