## 1. Contract and routing
- [ ] 1.1 Freeze source canonicalization, hash vectors, routing snapshot schema and batch metadata.
- [ ] 1.2 Implement explicit legacy/single-shard/multi-shard configuration and immutable routing epochs.
- [ ] 1.3 Route before batching and pin retries to their original stream/subject/epoch.

## 2. Topology and consumers
- [ ] 2.1 Implement central stream/consumer reconciliation, overlap rejection, ACLs and management visibility.
- [ ] 2.2 Divide logical retention budgets and report replicated cost/placement.
- [ ] 2.3 Share one persistence durable per shard across workers; bound fair demand and warehouse admission.
- [ ] 2.4 Preserve active StarRocks/CNPG behavior and required log side effects.

## 3. Migration and load
- [ ] 3.1 Verify readers-first migration, old-epoch draining, rollback and stable IDs without dual publication.
- [ ] 3.2 Exercise delayed ACKs, disconnected collectors, failed shards, redelivery and hot-source skew.
- [ ] 3.3 Benchmark single/multiple streams with equal durability and total capacity; enable based on evidence.
- [ ] 3.4 If shard workers share admission or demand state without a lock (2.3), model it with Loom in the change that adds it.
