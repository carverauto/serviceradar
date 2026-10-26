## ADDED Requirements

### Requirement: EventWriter workers run on every core replica
Every `serviceradar-core` replica that can hold the coordinator lock SHALL run the EventWriter worker pipelines whether or not it holds the lock. All replicas SHALL bind the same durable pull consumer for each stream, so that JetStream delivers each message to exactly one replica. Each replica SHALL pull into reply inboxes unique to it. Durable names, filter subjects and ACK cursors SHALL be the ones a single EventWriter used, so a rolling deploy resumes every cursor.

#### Scenario: Two replicas share one durable
- **GIVEN** two EventWriter producers bound to one durable on a JetStream broker
- **WHEN** messages are published to the durable's subject
- **THEN** every message SHALL be processed exactly once across the two producers
- **AND** both producers SHALL process messages

#### Scenario: A replica dies before acknowledging
- **GIVEN** a producer holding delivered but unacknowledged messages
- **WHEN** that producer and its connection die
- **THEN** the broker SHALL redeliver those messages after `ack_wait` to a surviving producer, which SHALL process each once

### Requirement: Only the coordinator changes EventWriter's JetStream state
EventWriter workers SHALL only read the JetStream server and pull from it: they SHALL NOT create, update or delete a stream or consumer. A durable a worker cannot find SHALL be retried with backoff. One coordinator-only consumer reconciler SHALL create and reconcile every EventWriter stream and durable on each (re)connect, delete retired durables once every live durable is up, run the stream ownership timer, and record the stream health events. A durable's `max_ack_pending` SHALL be the per-worker value times the number of pipelines bound to it.

#### Scenario: A replica's workers start before the durable exists
- **GIVEN** a worker tree started without the coordinator tree
- **WHEN** its producers connect
- **THEN** they SHALL issue only read-only JetStream requests and SHALL report not ready
- **AND** once the coordinator's reconciler creates the durables, they SHALL bind on their own retry

#### Scenario: Durable sizing
- **GIVEN** three worker replicas and a per-worker `max_ack_pending` of 256
- **WHEN** the reconciler creates a shared durable and a coordinator-only durable
- **THEN** the shared durable SHALL have `max_ack_pending` 768 and the coordinator-only durable 256

### Requirement: Processors that need one writer stay on the coordinator
A stream whose processor reads current state and writes a merge of it without a per-key lock or version fence SHALL be consumed only by a coordinator-only pipeline until that processor serializes per key itself. These are `ANALYTICS_PREDICTIONS`, `BMP_CAUSAL`, `ARANCINI_CAUSAL`, `SIEM_CAUSAL`, `K8S_INVENTORY` and `TRIVY`. Every other stream SHALL be consumed by every worker replica.

#### Scenario: Worker and coordinator stream split
- **WHEN** the worker tree and the coordinator tree load their configuration
- **THEN** the worker pipelines SHALL exclude exactly the coordinator streams and the coordinator pipeline SHALL consume exactly them

### Requirement: Stream Load concurrency is a deployment-wide budget
`analytics.starrocks.streamLoad.maxInFlight` SHALL bound concurrent Stream Loads across the deployment. Each core replica SHALL admit `max(1, div(maxInFlight, EVENT_WRITER_WORKERS))` loads at once, where Helm renders `EVENT_WRITER_WORKERS` from `core.replicas`. A replica's waiting queue SHALL keep the bounds derived from the undivided `maxInFlight`.

#### Scenario: Three replicas share four loads
- **GIVEN** `maxInFlight` 4 and 3 workers
- **WHEN** four loads are submitted to one replica at once
- **THEN** one SHALL run at a time and the others SHALL wait rather than fail back to JetStream

### Requirement: EventWriter health covers every replica
Cluster health SHALL report EventWriter as healthy only when every core replica that hosts EventWriter workers reports healthy, and SHALL list each replica's status. A replica that does not answer SHALL count as unhealthy.

#### Scenario: One replica's workers are down
- **GIVEN** three core replicas where one replica's worker pipeline is not ready
- **WHEN** cluster health runs
- **THEN** EventWriter SHALL be reported unhealthy with that replica's reason
