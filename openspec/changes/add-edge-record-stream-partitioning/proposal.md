# Change: Partition the edge-record streams and add the durable DLQ and retention

## Why

Every edge record lands on one `TELEMETRY_EDGE_RECORD_V1_BULK` stream with one shared EventWriter durable, the ledger and slot tables are unpartitioned, the catalogued result DLQ is not built yet (a minimal projection dead-letter is; see `docs/edge-record-dead-letter-runbook.md` and task 1.10), and nothing retires correctness metadata. That is enough for the current producers. It does not survive fleet-scale catch-up, systemic poison, or long retention.

Split out of `unify-sweep-results-proto` on 2026-11-02, when that change's task list was reconciled against `staging`. The requirements and tasks below moved verbatim; none of them blocks shipping the durable edge pipeline or archiving `unify-sweep-results-proto`.

## What Changes

- Provision installation-local, traffic-class-separated bulk, interactive, recovery and DLQ streams with an explicit logical-partition to physical-stream map.
- Partition the ingest ledger and slot tables by ordered time window and retire whole windows.
- Add the class-partitioned result DLQ with a catalog, state-aware deletion and redrive.
- Bound database capacity by explicit pools and partition consumers horizontally; tier sweep and MTR storage by query purpose.
- Reconcile runtime NATS provisioning with the single-customer installation model and add the governed service publisher.

## Impact

- Affected specs: cnpg, edge-producer-data-plane, ingestion-routing, nats-cross-account-consumption, nats-tenant-isolation.
- Affected code: Helm NATS stream templates, `ServiceRadar.EventWriter` stream config and consumers, ledger migrations, the gateway publisher routes.
- Depends on: `unify-sweep-results-proto`. The minimal projection dead-letter that task 3.5 required has landed; the catalog, states and redrive remain this change (task 1.10) and subsume it.
