# Change: Admit alert evaluation durably and process independent rules concurrently

## Why

StatefulAlertEngine currently waits for every shard's synchronous alert writes before returning. A slow shard delays unrelated signal batches (#5197), while competing Horde shard starts can drop an evaluation before it reaches an engine (#4511). Selecting matching shards alone, as proposed in PR #5343, does not provide durable admission or replay safety.

## What Changes

- **BREAKING internal completion contract:** successful `evaluate_logs/1`, `evaluate_events/1`, and `evaluate_metrics/1` mean durable acceptance, not visible alert effects. The result remains `:ok | {:error, reason}`; rejection never reports acceptance.
- Persist bounded, ordered evaluation work for matching rules in the deployment's CNPG control plane. A supervised pool processes independent rules without waiting on each other's alert writes.
- Commit evaluation completion, rule/group snapshots, alert lifecycle writes, and publication/notification outbox jobs atomically. Replays do not create another alert or count an input twice.
- Remove evaluation's dependency on Horde shard startup, closing the admission-side name-conflict loss path. Serialize maintenance against the same rule ownership and preserve its returned-count contract.
- Publish queue depth, queue age, rejection counts, and admission/evaluation latency through JetStream. Preserve EventWriter's exclusive StarRocks-or-CNPG telemetry persistence.
- Preserve threshold grouping, cooldown, recovery, seasonal disposition, and fire-once behavior. Use synthetic regression and load evidence on BuildBuddy/RBE.

## Impact

- Affected spec: observability-signals.
- Affected code: StatefulAlertEngine and its state machine/lifecycle, ProcessRegistry-dependent admission, Ash observability resources and migrations, worker supervision, EventWriter/log-promotion callers, liveness checks, tests, and telemetry publication.
- Integrate PR #5343's matching-rule routing once its implementation is verified and merged; do not duplicate its branch or close #5197 from this documentation PR.
- This is a proposal only. Refs #5197, Refs #4511. Implementation and merge of this proposal require the user's review.
