## MODIFIED Requirements
### Requirement: Sweep Results Push to Agent-Gateway

The agent SHALL push sweep results to the agent-gateway using the existing gRPC push protocol, emitting results only when sweep activity occurs and optionally providing progress batches for large sweeps.

#### Scenario: Agent pushes sweep completion results
- **GIVEN** an agent that has completed a sweep execution
- **WHEN** the sweep results are finalized
- **THEN** the agent SHALL push a completion batch via gRPC
- **AND** the batch SHALL include total hosts scanned, hosts available, and hosts failed
- **AND** the agent SHALL NOT emit periodic result pushes when no sweep has executed

#### Scenario: Agent pushes progress batches during large sweeps
- **GIVEN** a sweep execution with a large target set
- **WHEN** the agent reaches the configured progress threshold (count or time)
- **THEN** the agent SHALL push a progress batch via gRPC
- **AND** the batch SHALL include cumulative totals for the execution so far
- **AND** progress batches SHALL be rate-limited by configuration
