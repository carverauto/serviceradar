# Change: Run EventWriter workers on every core replica

## Why
`ServiceRadar.EventWriter.Supervisor` ran only under the coordinator, so the whole
ingestion pipeline (JetStream consumers, CNPG writes and StarRocks Stream Loads) ran
on one `serviceradar-core` replica. That replica carried nearly all ingestion CPU
while the other replicas idled, and adding replicas added failover, not throughput
(#5285).

## What Changes
- Every core replica runs the EventWriter worker pipelines (shared and flow). All
  replicas bind the same durable pull consumer per stream: the JetStream form of a
  NATS queue group. JetStream gives each message to exactly one replica, and load
  spreads with the replica count. Each replica pulls into reply inboxes unique to it.
- Workers only read the JetStream server (`STREAM.NAMES`, `CONSUMER.INFO`, pulls and
  ACKs). A new coordinator-only `EventWriter.ConsumerReconciler` owns every change to
  it: creating and reconciling streams and durables, deleting retired durables, the
  stream ownership timer, and the stream health events.
- The coordinator also keeps the duties that need one owner: the consumer lag
  reporter, the flow attribution correlator, and a coordinator-only pipeline for the
  streams whose processors rely on one writer per batcher (`ANALYTICS_PREDICTIONS`,
  `BMP_CAUSAL`, `ARANCINI_CAUSAL`, `SIEM_CAUSAL`, `K8S_INVENTORY`, `TRIVY`).
- `EVENT_WRITER_WORKERS`, which Helm renders from `core.replicas`, sizes each shared
  durable's `max_ack_pending` (per-worker value times the workers bound to it) and
  splits the StarRocks Stream Load `maxInFlight` across replicas. The deployment-wide
  meaning of `analytics.starrocks.streamLoad.maxInFlight` is the **behaviour change**
  operators see: each replica admits `max(1, maxInFlight / replicas)` loads.
- Cluster health reports EventWriter from every core replica, not only the coordinator.

## Impact
- Affected specs: `event-writer-placement` (new), `jetstream-storage-budget` (the
  ownership timer moves from the producer to the coordinator's reconciler).
- Affected code: `elixir/serviceradar_core/lib/serviceradar/event_writer/*`,
  `nats/jetstream_consumer.ex`, `analytics/starrocks/load_admission.ex`,
  `cluster/coordinator_children.ex`, `cluster/cluster_health.ex`, `application.ex`,
  `helm/serviceradar/templates/core.yaml`, `helm/serviceradar/values.yaml`.
- Rollout: durable names, filters and ACK cursors are unchanged, so a rolling deploy
  resumes every cursor. During the rollout an old coordinator can still reconcile a
  durable's `max_ack_pending` to its old value until it is replaced.
