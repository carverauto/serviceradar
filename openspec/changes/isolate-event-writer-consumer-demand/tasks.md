## 1. Demand isolation
- [x] 1.1 Group streams by the batcher their filter subject routes to and start one Broadway pipeline per group under the worker, flow and coordinator supervisors
- [x] 1.2 Divide the configured processor concurrency between a supervisor's groups; keep one batch processor per batcher
- [x] 1.3 Report health for every group pipeline; let the dev Broadway dashboard discover them

## 2. Per-record edge-record failure
- [x] 2.1 Return `{:incomplete, count, failures}` from `Processors.EdgeRecord.process_batch/1` so only raising records fail

## 3. Denied republish is terminal
- [x] 3.1 Record broker publish denials per connection and subject from the broker error log filter
- [x] 3.2 Fail a denied or held JetStream publish as `PublishDeniedError`; keep plain timeouts as timeouts
- [x] 3.3 Dead-letter an edge record whose republish was denied on its first delivery, logging the denial once per subject rather than per record

## 4. Expiry before delivery
- [x] 4.1 Poll every consumer's stream and report `expired_before_delivery`
- [x] 4.2 Alert on it in the Prometheus rules and log each durable's loss once

## 5. Verification
- [x] 5.1 Worker-tree regression: a stalled edge-record batcher does not stop another consumer's deliveries (fails on the shared pipeline)
- [x] 5.2 Real nats-server: a denied publish is classified and held; a silent publish times out
- [x] 5.3 Pipeline ack: a denied republish is dead-lettered on its first delivery
- [x] 5.4 CNPG: a raising record fails alone; a denied republish raises the denial and writes nothing
