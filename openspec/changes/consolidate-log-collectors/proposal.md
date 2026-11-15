# Change: Run UDP syslog, TCP syslog, and OTLP in one log collector

Status: approved for implementation by the product owner.

## Why

Flowgger accepts one configured input, so the chart starts another copy of the
collector to receive TCP alongside UDP. This duplicates workload,
configuration, health and NATS output ownership for one logical service.
Concurrent listeners are the foundation for the approved ingestion work.

## What Changes

- Add `[[inputs]]` beside `[input]`, sharing one logical output initialization.
  Preserve existing publisher-worker settings; keep OTLP in the process.
- Run optional TCP in the existing log-collector Deployment.
- **BREAKING:** remove the separate TCP Deployment, ConfigMap and external
  Service. Its replica/resource/stream-replica keys no longer create a workload.
- Keep the old TCP Service DNS name as an alias selecting unified TCP-listening
  pods, and retain its certificate SAN.
- Consolidate external TCP/UDP ports; reject conflicting pinned load-balancer
  addresses and divergent TCP output subjects.
- Update Compose, operator docs, Helm tests and pending references.

## Approved performance program

[performance.md](performance.md) and [zero-copy.md](zero-copy.md) explain the
source-backed findings. Three companion proposals own the extension contracts:

1. [Accelerate log ingestion](../accelerate-log-ingestion/proposal.md):
   bounded publication, collector-side Zen, datasvc rule snapshots and
   semantically equivalent protobuf/EventWriter consumption.
2. [Partition log ingestion](../partition-log-ingestion/proposal.md):
   independently led JetStream streams, routing and migration.
3. [Add zero-copy receivers](../add-zero-copy-log-receivers/proposal.md):
   supported Kubernetes/VM receive paths plus optional AF_XDP and ZC Rx.

The product owner approved finishing these contracts and starting implementation.
Approval does not establish benchmark gains or waive durability/semantic gates.
Consolidation ships independently and retains `logs.syslog` on `events`.

## Impact

- New capability: `log-collector`.
- Runtime: `rust/flowgger` and `rust/log-collector`.
- Deployment: collector templates, network policy, values, chart tests, Compose
  configuration and operator docs.
- Pending references: `update-demo-control-plane-ha`,
  `harden-pod-dns-and-cluster-resolver`,
  `update-documentation-accuracy-and-coverage`.
- No certificate-layout bump, telemetry backend removal or wire-format change
  in the consolidation slice.
