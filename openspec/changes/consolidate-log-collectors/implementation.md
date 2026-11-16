# Implementation handoff

Approval: product owner authorized proposal completion and implementation.
Implementation is in progress; no rollout or performance claim is complete.

## Current checkpoint

Branch: `feat/log-collector-pipeline`. Continue in the existing integration
worktree; the main checkout does not contain these changes. Integration base:
`1bc5ffe88321795f5cfabc72ef22fa24c63ca702`.

Committed foundations:

- `2071fdadb3`: four approved proposals and supporting research.
- `1866c7b0eb`: concurrent UDP/TCP listeners with independent codecs and one
  logical output; listener failures terminate the collector.
- `05ad9704f6`: consolidated Helm deployment and Compose listeners, compatibility
  TCP Service, custom target ports, documentation and chart regression coverage.
- `24c987ddaf`: count/byte-bounded concurrent JetStream publication, stable retry
  IDs, persistent queue handoff and source-close draining under retry policy.

- `d3dbb52142`: publisher tests for shared reconnect ownership and fail-closed
  certificate policy configuration; synthetic publish-window benchmark example
  and its first loopback measurement.
- `944957d5d1`: `rust/zen-normalize`, the shared ordered-rule normalization
  crate, with conformance cases whose expected records came from the JSON-text
  implementation.
- `6573ffe9e7`: the core Zen NIF evaluates through that crate.
- `a9b2c288e2`: the versioned rule bundle. Core publishes it from
  `ZenRuleSync`, and `rust/zen-normalize` verifies its digest and compiles it.
  Both sides assert the same frozen digests.

JSON remains the wire format. Flowgger does not call the shared Zen crate yet;
binary transport, stream sharding and specialized receivers are design
contracts, not implemented capabilities. Nothing from this branch has been
pushed or deployed.

## Evidence and remaining checks

- Combined Flowgger Cargo suite: 95 passed, zero failed, one intentionally ignored
  subprocess entrypoint. Includes real UDP/TCP delivery and broker ACK tests.
- Integrated focused Helm suite: 14 passed; Helm lint passed.
- Deployment agent's final full Helm suite: 490 tests in 106 suites passed.
- Individual Rust changes passed Clippy and formatting checks.
- Remote publisher tests passed in BuildBuddy invocation
  `1208ad67-b9ed-4efc-9a50-34878afab5be` before listener integration.
- Remote Helm/DNS/component gates passed in invocation
  `542922ef-8d34-4f05-953f-7a485597d876` before the final custom-port correction;
  that correction passed local regression coverage and the full Helm suite.
- Combined remote validation is still outstanding. The shared machine's Bazel
  concurrency limit prevented starting another server at this checkpoint.
- All four new OpenSpec proposals passed strict validation before this handoff;
  rerun validation after further edits.
- Since that checkpoint, Cargo only: Flowgger suite 97 passed, zero failed, one
  ignored; `serviceradar-zen-normalize` 5 passed; `zen_nif` builds; Clippy and
  rustfmt clean on all three. Each new publisher and normalization test was
  seen to fail against a mutated owner.
- Remote, at `a9b2c288e2`: BuildBuddy invocation
  `8c84ca18-6f0f-4329-b292-0e3a5dc6fcd7` passed Flowgger, zen-normalize, both
  log-collector tests, the full Helm unit suite, the pod DNS test and the
  component gates, and built the Zen NIF. Invocation
  `c1b0aa11-b398-4d79-9d97-a361f9416aa6` passed the core observability and
  event-writer unit shards, which compile the bundle changes and call the NIF
  from Elixir; a rerun of the observability shard reported 604 tests, 0
  failures. Its output does not list files, so the new bundle test is known to
  be in the shard's glob, not seen by name.
- Remote, after the field-removal fix and the revocation test: invocation
  `084f8b0c-b4ec-4e79-9c68-88a0c798b450` passed zen-normalize and the core
  observability (604 tests) and event-writer (582 tests) shards. Invocation
  `dd117274-86b0-4d49-b8a3-3ee80d2a8d38` passed both Flowgger targets; the
  revocation case ran, not skipped, in each. It has not been run against a
  mutated publisher.
- Remote, after removal became an explicit rule instruction: invocation
  `bfada610-cc2f-4b0e-b387-75d83ef8af4e` passed zen-normalize, the NIF build
  and the core observability shard. The event-writer shard passed on its
  second attempt; the first failed in `EdgeRecordRetentionNatsTest` on a NATS
  stream-info timeout, a test this branch does not touch.
- The seeder refresh of `strip_full_message` is exercised only by a database
  test, which no run above includes.
- Nothing has exercised bundle publication against a database or datasvc.
- The publish-window benchmark ran on a shared workstation over loopback. It
  shows serial publishing as the limit at window 1 and the listener and codec
  path as the limit from window 8 up. See `performance.md`; no multiplier is
  claimed.
- No live deployment smoke test or full-repository `make test` has been
  completed for this branch.
- Live operational inventory is not stored in the repository.

## Findings that need an owner

- Fixed on this branch at the product owner's direction: the bundled
  `strip_full_message` rule did not remove `full_message`, because Zen deletes
  a top-level `null` from a rule result and the overlay then kept the original.
  A rule now removes top-level fields by naming them in
  `serviceradar_remove_fields`. Only the bundled rule uses it, so no customer
  rule changes behavior; a rule that nulls a top-level field still removes
  nothing. Syslog records stop carrying `full_message` once the seeder has
  refreshed the seeded rule. A user-authored copy of that rule is left alone.
  An earlier attempt inferred removal from the rule graph and was replaced
  because it changed every rule of that shape.
- A number Zen's decimal cannot hold is replaced by `null` when a rule returns
  it inside a nested object or array. At the top level it survives. Also
  inherited, also preserved.
- A certificate policy revocation while ACKs are pending is covered by
  `//rust/flowgger:flowgger_managed_policy_test`, which needs uid 0 for the
  root-owned policy file. It skips on a workstation.
- The per-agent `_rules.json` index still orders by `order`, then name, and is
  scoped by agent. The new bundle follows core: stream and subject, `order`,
  then insertion time. The web-ng rules settings page still lists the
  per-agent keys, so they stay until that page reads something else.

## Next agent prompt

Read this handoff, tasks, choices and the three companion proposals. First run
combined remote Flowgger, zen-normalize, Zen NIF, log-collector and Helm checks
when the shared Bazel limit permits. Preserve Build-volume worktree and
remote-rc requirements. Then publish versioned rules through datasvc (2.3) and
consume them in the collector (2.4, 2.2a), in parallel with binary-reader
field/persistence parity where ownership permits. Deploy readers
before enabling normalized protobuf producers. Keep JSON compatibility until
that transition is verified. Do not mark live rollout complete from unit tests.

Use one JetStream stream with parallel durable pull workers initially. Subject
routing can distribute processing without separate streams. Independent stream
shards remain optional and require a demonstrated broker ingestion/storage
bottleneck, suitable placement and equal-durability benchmarks. The user's latest
clarification rejects treating Kafka-style partitioning as a prerequisite.

Portable receive improvements and AF_XDP/ZC Rx prototypes use the same future
normalization/publishing contract. Consumer replacement and warehouse format
changes require equivalent semantics and measured benefit. They are experiments,
not presumed bottlenecks. Keep this handoff current and all unverified tasks open.
