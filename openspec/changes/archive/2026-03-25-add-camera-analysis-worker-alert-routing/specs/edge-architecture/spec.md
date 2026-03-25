## ADDED Requirements
### Requirement: Worker alert routing uses authoritative registry state
The platform SHALL derive camera analysis worker alert routing inputs from the authoritative worker registry and runtime alert-transition path rather than from a parallel health model.

#### Scenario: Runtime transition produces routed alert input
- **WHEN** authoritative worker alert state changes in response to probe or dispatch-driven runtime updates
- **THEN** the platform SHALL build routed alert input from that same updated worker state
- **AND** the routed alert input SHALL include normalized worker identity and alert metadata

### Requirement: Worker alert routing preserves analysis-worker context
The platform SHALL preserve enough worker context in routed signals for operators to identify the affected worker and reason about the degradation cause.

#### Scenario: Routed worker alert includes context
- **WHEN** a worker alert transition is routed into the observability pipeline
- **THEN** the routed signal SHALL include the worker id
- **AND** it SHALL include normalized context such as adapter, capability, or failover reason when available
