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

JSON remains the wire format. Native Zen, binary transport, stream sharding and
specialized receivers are design contracts, not implemented capabilities.
Nothing from this branch has been pushed or deployed.

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
- No synthetic throughput benchmark, live deployment smoke test or full-repository
  `make test` has been completed for this branch. No speedup is claimed.
- Live operational inventory is not stored in the repository.

## Next agent prompt

Read this handoff, tasks, choices and the three companion proposals. First run
combined remote Flowgger, log-collector and Helm checks when the shared Bazel
limit permits. Preserve Build-volume worktree and remote-rc requirements. Finish
publisher reconnect/certificate coverage and a reproducible synthetic benchmark.
Then implement shared native Zen and versioned datasvc rules, in parallel with
binary-reader field/persistence parity where ownership permits. Deploy readers
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
