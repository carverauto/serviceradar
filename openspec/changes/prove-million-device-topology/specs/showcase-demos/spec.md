## ADDED Requirements

### Requirement: Network-scale simulation exercises the production topology and telemetry paths
The demo suite SHALL provide an independently invented, deterministic network scenario supporting one million devices and at least two million relations, with stable interface bindings and independently configurable telemetry population and cadence. Generation SHALL be bounded per shard and batch, and repeated runs SHALL preserve identities. The simulator SHALL use existing topology import/API paths or controlled direct topology seeding into owned isolated storage, and SHALL identify bypassed ingestion layers and counts in each populated store. Physical devices and WASM SHALL NOT be prerequisites. Cumulative SNMP packet/octet metric envelopes SHALL pass through JetStream and EventWriter, using a native publisher or optional SDK `emit_telemetry`. It SHALL NOT seed metric tables directly or replace God View's HTTP/channel responses with fabricated overlays for end-to-end acceptance.

#### Scenario: Measurable million-device deployment
- **WHEN** the one-million-device scenario has completed ingestion in an isolated synthetic deployment
- **THEN** verification SHALL count one million persisted devices and at least two million topology relations with resolvable endpoints
- **AND** SHALL report the number of devices and interfaces actively emitting telemetry, their sample cadence, ingest lag and offered rate separately from topology size
- **AND** a partial ingestion SHALL fail verification even when the producer reports success

#### Scenario: Traffic lifecycle reaches the real renderer
- **WHEN** synthetic SNMP counters change from positive traffic to measured zero, stop reporting, reset and resume
- **THEN** SRQL and the real God View overlay SHALL reflect those states without treating missing counters as zero or reset discontinuities as spikes
- **AND** hardware WebGPU verification SHALL observe directional traffic animation without requiring multicast or broadcast counters
- **AND** telemetry changes SHALL NOT refetch unchanged tile geometry

#### Scenario: Synthetic isolation and replay
- **WHEN** an operator repeats or stops a network-scale run
- **THEN** the run SHALL affect only its isolated synthetic deployment and graph, never live data or another CI run's graph
- **AND** repeated batches SHALL NOT multiply device identities or topology relations
- **AND** teardown verification SHALL query owned records after producers have stopped

#### Scenario: Opening and exploring the network
- **WHEN** an authenticated user opens the scenario in God View
- **THEN** the initial camera SHALL cover the world overview and the displayed device counts SHALL account for the complete generated population
- **AND** zooming SHALL reveal bounded levels of detail and selection SHALL open a bounded ELK neighborhood
- **AND** returning from detail SHALL preserve the user's map position
