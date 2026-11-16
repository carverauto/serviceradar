# Change: Scale durable log ingestion across JetStream streams

Status: approved design and implementation program; production enablement is
gated on migration and load evidence.

## Why

A single JetStream stream has one write leader. More subjects, collector pods
or consumers do not create Kafka-style partitions within it. Independent streams
can distribute leader work and, with suitable placement, storage/replication
load. The current stream has not been measured as the limiting stage.

## What Changes

- Add optional deterministic routing into a bounded number of independent
  log streams, each owning disjoint subjects.
- Give each shard a shared durable persistence consumer and bounded worker
  demand. Additional subscriber purposes use separate named durables.
- Provision stream/consumer topology centrally with explicit replica,
  retention, placement and aggregate capacity budgets.
- Version routing layouts as immutable epochs and retain retry destinations.
- Migrate readers, permissions and monitoring before switching collectors.
- Preserve a single-stream deployment option and existing legacy draining.

## Impact

Touches collector routing/batching, NATS topology reconciliation and budgets,
publisher ACLs, EventWriter subscriptions, metrics and rollout tooling.
It does not create a stream per host, bypass JetStream, introduce multitenancy,
or promise global order/exactly-once effects.
