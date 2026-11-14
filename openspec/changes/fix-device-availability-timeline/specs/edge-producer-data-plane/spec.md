## ADDED Requirements

### Requirement: Core derives per-host sweep gauges for leased executions
Core SHALL derive the per-host sweep gauges of every projected leased sweep batch (`SweepObservationBatchV1` on `serviceradar.sweep.observation`) and publish them through JetStream on `metrics.sweep.>`, so a leased sweep produces the same per-host availability telemetry an unleased sweep does.
The derivation SHALL run only after the ledger transaction that projected the batch commits, and only for a fresh primary delivery. A replay, a late-fenced delivery, or a batch whose projection was refused SHALL NOT produce gauges.
The gauges SHALL be `sweep.host.available` (ICMP target reached or any tested TCP port open), `sweep.host.icmp_available`, `sweep.host.icmp_response_time_ns`, `sweep.host.icmp_packet_loss`, `sweep.host.port.available` and `sweep.host.port.response_time_ns`, each present only when the batch carries its input, observed at the host's observation time, tagged `target`, `hostname` (when present), `execution_id` and `sweep_group_id`, and attributed to the record's authenticated agent with the source, producer kind, metric type and service identity the unleased sweep-results batch carries after core attests it.
Each published message SHALL hold at most 1,000 points and carry a message id derived from the record's event id and the message's index, so a retried publish is stored once. The agent SHALL NOT emit a metric batch for a leased execution.

#### Scenario: A leased sweep produces per-host availability telemetry
- **GIVEN** an agent whose only sweep group is leased
- **WHEN** a batch of its leased execution projects and the ledger commits
- **THEN** core publishes `sweep.host.available` for every host in the batch on `metrics.sweep.>`, attributed to that agent
- **AND** EventWriter stores the gauges like the agent's unleased gauges

#### Scenario: A refused or replayed batch produces no gauges
- **WHEN** a leased batch's projection is refused, or the delivery is a replay or late-fenced
- **THEN** core publishes no per-host gauges for it

#### Scenario: A large batch is split into bounded messages
- **GIVEN** a leased batch whose hosts yield more than 1,000 points
- **WHEN** core derives its gauges
- **THEN** it publishes them in host order in messages of at most 1,000 points
- **AND** each message's id is the record's event id with the message index, stable across retries

#### Scenario: A failed publish is retried durably
- **WHEN** the JetStream publish of derived gauges fails
- **THEN** the message is stored as a durable retry job and published under the same message id once JetStream accepts it
