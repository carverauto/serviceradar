## 1. Placement
- [x] 1.1 Start `EventWriter.Supervisor` (workers) on every core replica that can be coordinator, outside the coordinator lock
- [x] 1.2 Add `EventWriter.CoordinatorSupervisor` under the coordinator with the consumer reconciler, the coordinator pipeline, the lag reporter and the flow correlator
- [x] 1.3 Keep streams whose processors need one writer on the coordinator pipeline (`Config.coordinator_stream?/1`)

## 2. Consumer setup split
- [x] 2.1 Add read-only `JetstreamConsumer.bind_durable/2`; producers bind and never create, update or delete
- [x] 2.2 Move stream/durable reconciliation, retired-durable deletion, the ownership timer and stream health events to `EventWriter.ConsumerReconciler`
- [x] 2.3 Size each shared durable's `max_ack_pending` by the workers bound to it

## 3. Budgets and health
- [x] 3.1 Split the Stream Load `max_in_flight` across `EVENT_WRITER_WORKERS`; keep the per-node waiting bounds
- [x] 3.2 Report each core replica's EventWriter health in cluster health
- [x] 3.3 Render `EVENT_WRITER_WORKERS` from `core.replicas` in Helm, with a unittest

## 4. Verification
- [x] 4.1 Worker tree binds the reconciler's durables and issues only read-only JetStream requests (fake broker)
- [x] 4.2 Reconciler: placement failure isolation, retirement after all durables are up, health transitions, durable sizing
- [x] 4.3 Two producers on one durable against a real disposable nats-server: each message once, and a dead producer's unacknowledged messages redelivered to the survivor
- [x] 4.4 Stream Load admission admits one node's share and keeps the full waiting queue
