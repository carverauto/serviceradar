## Context

The current front door calls every shard synchronously. A shard loads rules and snapshots and performs state-machine and alert lifecycle writes in its callback. Its `:ok` therefore promises visible effects. Some callers, including the anomaly liveness check and integration tests, depend on that completion contract. The existing `DurablePublish.publish/3` already uses an Oban outbox when called inside a database transaction, and resolution already commits its notification job with its alert transition.

## Goals / Non-Goals

Goals are durable bounded acceptance, ordered evaluation within each rule, independent progress across rules, and unchanged alert lifecycle outcomes. This does not add a second alert engine, resurrect the central anomaly pipeline, or create a new telemetry store. CNPG work rows are transient control-plane queue state; telemetry still originates through JetStream and telemetry queries never read these rows.

## Decisions

### D1: Commit bounded admission before returning success

Introduce an Ash-owned evaluation inbox and completion receipts in the platform schema. A short admission transaction captures the eligible rule IDs and immutable rule revisions, reserves configured per-rule and deployment-wide count/byte capacity, and inserts all work for a batch. The transaction is all-or-nothing. Admission uses a bounded timeout and returns explicit overload, unavailable-store, or invalid-payload errors. It never waits on an evaluator, nor acknowledges only part of a batch. Accepted work is not evicted to admit newer work.

Each admission has a stable identity derived from upstream delivery identity where available. Direct callers receive an internally generated identity; ambiguous caller retries may duplicate admission, so lifecycle and record identities also need durable deduplication. Identity and dedup horizons must cover source redelivery and inbox retention, not merely JetStream's short duplicate window. Hashing a batch alone must not collapse legitimate distinct occurrences with equal content.

### D2: Serialize one rule, not every shard

A supervised bounded worker pool drains oldest eligible work for each rule. Admission allocates per-rule commit order while holding a short rule-specific transaction lock; a global sequence allocated before commit is insufficient. Evaluation claims are fenced in CNPG so two nodes cannot advance the same rule concurrently. Rule processing uses a separate ownership key from admission so slow evaluation does not hold up enqueue. Claim recovery must revoke stale owners before a replacement can commit.

Persist a rule revision with accepted work. Edits affect subsequently admitted work; disabling or deleting a rule cancels its pending work through an explicit, durable disposition rather than silently executing a disabled rule. Inventory all rule/state writers, including raw Ecto, before implementing this contract. Rule identity remains stable across revisions, preserving order. PR #5343's signal routing can supply candidates; actual record matching remains the state machine's responsibility. A rule read failure fails admission closed rather than routing to an incomplete set.

Evaluation admission does not start or call a Horde process, so a concurrent registration conflict cannot discard accepted work. Retained maintenance operations, including stale-anomaly resolution, use the same ownership fencing and drain an ordering barrier before returning their existing resolved count. Remove obsolete shard-start paths only after every caller has migrated.

### D3: Commit lifecycle outcomes with the completion receipt

Within the owner transaction, reload authoritative rule/group state, run the existing matcher and state machine, persist every changed snapshot even when its bucket has not advanced, and commit alert/history/notification changes together with the input receipt and inbox completion. Mutable ETS state is a disposable working copy, not a durable receipt. A failed transaction discards it before retry.

Use the existing DurablePublish transaction outbox for generated OCSF events. Event IDs, incident identities, and notification identities must remain stable across replay. Outbox publication still goes through JetStream and EventWriter; never insert generated OCSF telemetry directly into CNPG or StarRocks. Commit before reporting processing success or removing queue work. Test crash points before commit, after commit but before completion observation, and after an outbox publish but before its acknowledgement is recorded.

Retries use backoff and do not let later inputs overtake a failed input for the same rule. A permanently invalid input receives an explicit audited terminal disposition and health signal; it is never silently dropped. Receipt pruning cannot precede the supported replay horizon. Completed work is bounded by retention; pending work is bounded by admission, not destructive TTL cleanup.

### D4: Update callers and expose completion honestly

Audit every evaluation caller, including aliases and dynamic dispatch. EventWriter and promotion paths may acknowledge upstream input only after durable admission. Preserve their error propagation. Liveness checks and tests must await the persisted alert or a durable completion receipt with a bounded timeout; a sleep or success-shaped mock is not proof. Maintenance APIs keep their current synchronous result shape. Avoid a new indefinitely blocking completion API on normal ingestion paths.

### D5: JetStream telemetry and rollout

Use bounded labels (signal, outcome, fixed lane/shard identity), never rule IDs or record identities as metric labels. Publish interval deltas and queue/latency measurements through JetStream, retaining the prior frame until PubAck. EventWriter chooses the warehouse when enabled and CNPG otherwise. Surface oldest pending work, rejected admission, retrying work, and permanently failed work in health diagnostics.

Install schema and consumers first, then migrate callers and enable durable admission only after capability verification. During a mixed-version rollout, a rule must have exactly one owner and one completion contract; never run old inline evaluation and new queued evaluation for the same input. Fail closed when the required capability is absent. Before rollback, stop new admission and drain/fence accepted work; queued work cannot be abandoned by switching to an older image.

## Risks / Trade-offs

Durable admission adds short CNPG control-plane transactions and storage; limits and retention bound that cost. Alert effects become eventually visible after acceptance. Per-rule ownership and transactional lifecycle work require changes beyond a GenServer cast; using casts alone would lose work on restart. DurablePublish's outbox avoids a database/JetStream split-brain publication, but its existing replay guarantees must be tested rather than assumed.

## Validation

PR BazelCI is the compiled proof. Tests use invented fixtures, no expected-test-count pins, and the test-audit owner-boundary rules. A paused evaluator must not delay another rule's admission or persistence. Interleaved signal batches must retain each rule's order. Restart and crash-point tests assert exactly one alert, correct occurrence counts, durable receipts, and recoverable outbox work. Synthetic load evidence distinguishes admission latency from effect latency and reports rejection, queue bytes, and pool occupancy. Live rollout proof remains separately identified if not driven.
